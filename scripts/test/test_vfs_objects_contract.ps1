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

Write-Host 'VFS objects: compiling fixed-pool object core...' -ForegroundColor Yellow
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
# gritc intentionally classifies raw_mem + implicit_extern as broad capabilities.
# Pin that exact reviewed set rather than pretending a module-owned BSS pool is
# zero-unsafe or allowing future broad authority to hide beside it.
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
if ($src -notmatch '(?s)fn\s+vfs_file_close\(token\).*?vfs_file_exists\(token\).*?sb\(&vfs_file_active\s*\+\s*i,\s*0\);.*?vfs_next_generation') {
    throw 'File close must accept stale-node lifetime tokens and invalidate generation on close'
}
if ($src -notmatch '(?s)fn\s+vfs_node_free\(token\).*?if\s+lw\(&vfs_node_refs\s*\+\s*i\s*\*\s*4\)\s*!=\s*0\s*\{\s*return\s+0;') {
    throw 'Node free no longer rejects referenced nodes'
}
if ($src -notmatch '(?s)fn\s+vfs_node_mark_stale\(token\).*?VFS_NODE_STALE') {
    throw 'VFS node layer lost explicit stale state for backend slot reuse'
}
if ($src -notmatch '(?s)fn\s+vfs_node_validate\(token\).*?VFS_NODE_LIVE') {
    throw 'Operational node validation no longer rejects stale objects'
}
if ($src -notmatch '(?s)fn\s+vfs_file_alloc\(node_token,\s*flags,\s*rights\).*?vfs_open_flags_valid\(flags\)') {
    throw 'VFS file allocation no longer validates open flags'
}
if ($src -notmatch 'const\s+VFS_NODE_CAP\s*=\s*128;') { throw 'VFS node pool bound drifted' }
if ($src -notmatch 'const\s+VFS_FILE_CAP\s*=\s*128;') { throw 'VFS file pool bound drifted' }
if ($src -match '(?m)^\s*(malloc|alloc|heap_)') { throw 'VFS fixed-pool object layer unexpectedly allocates dynamically' }

Write-Host 'VFS objects: PASS (bounded pools, stale-safe lifetime, exact unsafe set, immutable rights).' -ForegroundColor Green
