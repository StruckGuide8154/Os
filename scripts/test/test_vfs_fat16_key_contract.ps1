# Compile/security gate for the pure FAT16 VFS backend-key codec.

$ErrorActionPreference = 'Stop'
$Root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$Compiler = Join-Path $Root 'src\user\grithl\compiler\gritc.py'
$Source = Join-Path $Root 'src\kernel\grithlk\vfs_fat16_key.ghl'
$Lib = Join-Path $Root 'src\user\grithl\lib'
$OutDir = Join-Path $Root 'build\test-vfs'
$Asm = Join-Path $OutDir 'vfs_fat16_key.asm'
$Safety = Join-Path $OutDir 'vfs_fat16_key.safety.json'

New-Item -Path $OutDir -ItemType Directory -Force | Out-Null
Write-Host 'VFS FAT16 key: compiling pure identity codec...' -ForegroundColor Yellow
& python $Compiler $Source -o $Asm -L $Lib --embed --target kernel --forbid-asm --safety-manifest $Safety
if ($LASTEXITCODE -ne 0) { throw 'vfs_fat16_key.ghl failed GritHLK compilation' }

$m = Get-Content -Raw -Path $Safety | ConvertFrom-Json
if (@($m.unsafe.declared).Count -ne 0) { throw 'FAT16 VFS key codec must remain zero-unsafe' }
if (@($m.unsafe.broad).Count -ne 0) { throw 'FAT16 VFS key codec uses broad unsafe authority' }
if (@($m.unsafe.privileged).Count -ne 0) { throw 'FAT16 VFS key codec uses privileged unsafe authority' }

$src = Get-Content -Raw -Path $Source
if ($src -match 'fat16_root_cache|fat16_file_buf|raw_mem') {
    throw 'FAT16 VFS identity codec must not depend on live cache pointers/raw memory'
}
if ($src -notmatch 'const\s+F16K_RAW_SLOT_CAP\s*=\s*512;') {
    throw 'FAT16 raw directory-slot bound drifted from the 16 KiB cache contract'
}
if ($src -notmatch '(?s)fn\s+vfs_fat16_key_make_root\(\).*?F16K_KIND_ROOT') {
    throw 'FAT16 root does not have a distinct typed identity'
}
if ($src -notmatch '(?s)fn\s+vfs_fat16_key_make_entry\(parent_cluster,\s*raw_slot\).*?raw_slot\s*>=\s*F16K_RAW_SLOT_CAP') {
    throw 'FAT16 entry identity lost its raw-slot bounds check'
}

Write-Host 'VFS FAT16 key: PASS (zero unsafe, typed stable location key, bounded raw slot).' -ForegroundColor Green
