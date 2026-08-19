# Compile/safety gate for generation-safe VFS node/file fixed pools.

$ErrorActionPreference = 'Stop'
$Root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$Compiler = Join-Path $Root 'src\user\grithl\compiler\gritc.py'
$Source = Join-Path $Root 'src\kernel\grithlk\vfs_objects.ghl'
$Lib = Join-Path $Root 'src\user\grithl\lib'
$OutDir = Join-Path $Root 'build\test-vfs'
$Asm = Join-Path $OutDir 'vfs_objects.asm'
$Safety = Join-Path $OutDir 'vfs_objects.safety.json'

New-Item -Path $OutDir -ItemType Directory -Force | Out-Null
if (-not (Test-Path $Source)) { throw 'Missing vfs_objects.ghl' }

Write-Host 'VFS objects: compiling synchronized fixed-pool object core...' -ForegroundColor Yellow
& python $Compiler $Source -o $Asm -L $Lib --embed --target kernel --forbid-asm --safety-manifest $Safety
if ($LASTEXITCODE -ne 0) { throw 'vfs_objects.ghl failed GritHLK compilation' }
if (-not (Test-Path $Safety)) { throw 'Missing VFS object safety manifest' }

$m = Get-Content -Raw -Path $Safety | ConvertFrom-Json
$declared = @($m.unsafe.declared | ForEach-Object {
    if ($null -ne $_.cap) { [string]$_.cap } else { [string]$_ }
} | Sort-Object)
$expected = @('implicit_extern', 'raw_mem')
if (($declared -join ',') -ne ($expected -join ',')) {
    throw "VFS object unsafe surface drifted: expected [$($expected -join ', ')], got [$($declared -join ', ')]"
}
$broad = @($m.unsafe.broad | ForEach-Object { [string]$_ } | Sort-Object)
if (($broad -join ',') -ne ($expected -join ',')) {
    throw "VFS object broad-capability set drifted: expected [$($expected -join ', ')], got [$($broad -join ', ')]"
}
if (@($m.unsafe.privileged).Count -ne 0) { throw 'VFS objects use a privileged unsafe capability' }

$src = Get-Content -Raw -Path $Source
if ($src -match '(?m)^\s*unsafe\s+(asm|raw_io|syscall|user_mem|kernel_priv|kernel_io)\b') {
    throw 'VFS object layer gained forbidden authority beyond module-owned memory'
}
if ($src -match '(?m)^global\s+vfs_file_set_rights\s*;') {
    throw 'Immutable VFS file rights gained a widening setter'
}
if ($src -notmatch '(?s)fn\s+vfs_file_close\(token\).*?vfs_lock_acquire\(VFS_OBJ_LOCK_ID,\s*VFS_OBJ_LOCK_SPINS\).*?vfs_file_exists_unlocked\(token\).*?sb\(&vfs_file_active\s*\+\s*i,\s*0\);.*?vfs_next_generation') {
    throw 'File close is not serialized/stale-safe/generation-invalidating'
}
if ($src -notmatch '(?s)fn\s+vfs_node_free\(token\).*?vfs_lock_acquire\(VFS_OBJ_LOCK_ID,\s*VFS_OBJ_LOCK_SPINS\).*?lw\(&vfs_node_refs\s*\+\s*i\s*\*\s*4\)\s*==\s*0') {
    throw 'Node free no longer serializes and requires zero references'
}
if ($src -notmatch '(?s)fn\s+vfs_node_mark_stale\(token\).*?vfs_lock_acquire.*?VFS_NODE_STALE') {
    throw 'VFS node stale transition is not serialized'
}
if ($src -notmatch '(?s)fn\s+vfs_node_validate_unlocked\(token\).*?VFS_NODE_LIVE') {
    throw 'Operational node validation no longer rejects stale objects'
}
if ($src -notmatch '(?s)fn\s+vfs_file_alloc\(node_token,\s*flags,\s*rights\).*?vfs_open_flags_valid\(flags\).*?vfs_lock_acquire') {
    throw 'VFS file allocation is not flag-validated and serialized'
}
if ($src -notmatch '(?s)fn\s+vfs_node_find_live_unlocked\(fs_id,\s*key0,\s*key1\).*?vfs_node_fs_id.*?vfs_node_key0.*?vfs_node_key1') {
    throw 'Canonical live-node lookup by backend identity is missing'
}
if ($src -notmatch '(?s)fn\s+vfs_file_open_object\(fs_id,\s*key0,\s*key1,\s*obj_type,\s*size,\s*flags,\s*rights\).*?vfs_lock_acquire.*?vfs_node_find_live_unlocked.*?vfs_file_alloc_unlocked.*?vfs_lock_release') {
    throw 'Atomic canonical materialize+open primitive is missing'
}
if ($src -notmatch 'const\s+VFS_NODE_CAP\s*=\s*128;') { throw 'VFS node pool bound drifted' }
if ($src -notmatch 'const\s+VFS_FILE_CAP\s*=\s*128;') { throw 'VFS file pool bound drifted' }
if ($src -match '(?m)^\s*(malloc|alloc|heap_)') { throw 'VFS fixed-pool object layer unexpectedly allocates dynamically' }

Write-Host 'VFS objects: PASS (bounded pools, no-steal serialization, canonical identity, stale safety, immutable rights).' -ForegroundColor Green
