# Compile/security gate for the read-only FAT16 -> VFS materialization seam.

$ErrorActionPreference = 'Stop'
$Root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$Compiler = Join-Path $Root 'src\user\grithl\compiler\gritc.py'
$Source = Join-Path $Root 'src\kernel\grithlk\vfs_fat16_backend.ghl'
$Lib = Join-Path $Root 'src\user\grithl\lib'
$OutDir = Join-Path $Root 'build\test-vfs'
$Asm = Join-Path $OutDir 'vfs_fat16_backend.asm'
$Safety = Join-Path $OutDir 'vfs_fat16_backend.safety.json'

New-Item -Path $OutDir -ItemType Directory -Force | Out-Null
Write-Host 'VFS FAT16 backend: compiling bounded read-only materializer...' -ForegroundColor Yellow
& python $Compiler $Source -o $Asm -L $Lib --embed --target kernel --forbid-asm --safety-manifest $Safety
if ($LASTEXITCODE -ne 0) { throw 'vfs_fat16_backend.ghl failed GritHLK compilation' }

$m = Get-Content -Raw -Path $Safety | ConvertFrom-Json
$declared = @($m.unsafe.declared | ForEach-Object { if ($null -ne $_.cap) { [string]$_.cap } else { [string]$_ } } | Sort-Object)
$expected = @('implicit_extern','raw_mem')
if (($declared -join ',') -ne ($expected -join ',')) {
    throw "FAT16 VFS backend unsafe surface drifted: expected [$($expected -join ', ')], got [$($declared -join ', ')]"
}
if (@($m.unsafe.privileged).Count -ne 0) { throw 'FAT16 VFS backend gained privileged unsafe authority' }

$src = Get-Content -Raw -Path $Source
if ($src -match '(?m)^\s*unsafe\s+(asm|raw_io|user_mem|syscall|kernel_priv|kernel_io)\b') {
    throw 'FAT16 VFS backend gained authority beyond bounded kernel-memory inspection'
}
if ($src -notmatch 'const\s+VFS_LOCK_FAT_BACKEND\s*=\s*2;') {
    throw 'FAT16 backend lock ID drifted from vfs_lock contract'
}
if ($src -notmatch '(?s)fn\s+vfs_fat16_materialize_raw\(.*?vfs_lock_acquire\(VFS_LOCK_FAT_BACKEND.*?fat16_change_dir\(parent_cluster\).*?f16b_materialize_loaded.*?vfs_lock_release\(VFS_LOCK_FAT_BACKEND\)') {
    throw 'Raw-slot materialization is not contained by the FAT backend lock'
}
if ($src -notmatch '(?s)fn\s+vfs_fat16_lookup_component\(.*?vfs_lock_acquire\(VFS_LOCK_FAT_BACKEND.*?fat16_change_dir\(parent_cluster\).*?vfs_fat16_entry_classify.*?f16b_entry_name_matches.*?vfs_lock_release\(VFS_LOCK_FAT_BACKEND\)') {
    throw 'Component lookup lost lock/load/filter/match/release ordering'
}
if ($src -notmatch '(?s)fn\s+f16b_materialize_loaded\(.*?vfs_fat16_entry_cluster_valid.*?vfs_fat16_key_make_entry.*?vfs_open_object_checked') {
    throw 'Backend materialization no longer validates metadata/key/open authority before VFS object creation'
}
if ($src -match '(?m)^reserve\s+.*fat16.*(ptr|entry|cache)') {
    throw 'FAT16 backend introduced persistent storage for a live cache pointer'
}
if ($src -notmatch '(?s)fn\s+f16b_component_shape\(name,\s*length\).*?length\s*>\s*12.*?base_len\s*>\s*8.*?ext_len\s*>\s*3') {
    throw 'Conservative FAT 8.3 component bounds drifted'
}

Write-Host 'VFS FAT16 backend: PASS (bounded transient cache view, stable raw-slot key, checked open authority).' -ForegroundColor Green
