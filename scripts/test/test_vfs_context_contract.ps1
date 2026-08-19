# Compile/security gate for per-slot VFS root/cwd contexts.

$ErrorActionPreference = 'Stop'
$Root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$Compiler = Join-Path $Root 'src\user\grithl\compiler\gritc.py'
$Source = Join-Path $Root 'src\kernel\grithlk\vfs_context.ghl'
$Lib = Join-Path $Root 'src\user\grithl\lib'
$OutDir = Join-Path $Root 'build\test-vfs'
$Asm = Join-Path $OutDir 'vfs_context.asm'
$Safety = Join-Path $OutDir 'vfs_context.safety.json'

New-Item -Path $OutDir -ItemType Directory -Force | Out-Null
Write-Host 'VFS context: compiling per-slot namespace state...' -ForegroundColor Yellow
& python $Compiler $Source -o $Asm -L $Lib --embed --target kernel --forbid-asm --safety-manifest $Safety
if ($LASTEXITCODE -ne 0) { throw 'vfs_context.ghl failed GritHLK compilation' }

$m = Get-Content -Raw -Path $Safety | ConvertFrom-Json
$declared = @($m.unsafe.declared | ForEach-Object { if ($null -ne $_.cap) { [string]$_.cap } else { [string]$_ } } | Sort-Object)
$expected = @('implicit_extern','raw_mem')
if (($declared -join ',') -ne ($expected -join ',')) {
    throw "VFS context unsafe surface drifted: [$($declared -join ', ')]"
}
if (@($m.unsafe.privileged).Count -ne 0) { throw 'VFS context gained privileged unsafe authority' }

$src = Get-Content -Raw -Path $Source
if ($src -notmatch 'const\s+VFS_CTX_SLOTS\s*=\s*12;') { throw 'VFS context slot bound drifted' }
if ($src -notmatch 'const\s+VFS_CTX_LOCK_BASE\s*=\s*3;') { throw 'VFS context lock-ID base drifted from vfs_lock contract' }
if ($src -notmatch '(?s)fn\s+vfs_ctx_chdir_to_node\(slot,\s*dir_node,\s*rights\).*?vfs_lock_acquire\(lid,\s*VFS_CTX_LOCK_SPINS\).*?vfs_rights_subset\(root_rights,\s*rights\)\s*==\s*0') {
    throw 'chdir no longer serializes and attenuates rights against the slot root'
}
if ($src -notmatch '(?s)fn\s+vfs_ctx_init_slot\(slot,\s*root_node,\s*rights\).*?vfs_node_get_type\(root_node\)\s*!=\s*VFS_OBJ_DIR.*?vfs_lock_acquire\(lid,\s*VFS_CTX_LOCK_SPINS\)') {
    throw 'slot init no longer requires a directory root and a per-slot lock'
}
if ($src -notmatch '(?s)fn\s+vfs_ctx_reset_unlocked\(slot\).*?sq\(cp,\s*0\);.*?sq\(rp,\s*0\);.*?vfs_ctx_bump_epoch\(slot\);.*?vfs_file_close') {
    throw 'context reset no longer unpublishes before closing private files'
}
if ($src -notmatch '(?s)fn\s+vfs_ctx_reset_slot\(slot\).*?vfs_lock_acquire\(lid,\s*VFS_CTX_LOCK_SPINS\).*?vfs_ctx_reset_unlocked\(slot\).*?vfs_lock_release\(lid\)') {
    throw 'public context reset is not serialized by the slot lock'
}
if ($src -match '(?m)^\s*unsafe\s+(asm|raw_io|syscall|user_mem|kernel_priv|kernel_io)\b') {
    throw 'VFS context gained authority beyond module-owned state'
}

Write-Host 'VFS context: PASS (per-slot root/cwd, no-steal mutation locks, rights attenuation, bounded state).' -ForegroundColor Green
