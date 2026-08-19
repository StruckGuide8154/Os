# Compile/security gate for the pure FAT16 metadata firewall used by VFS.

$ErrorActionPreference = 'Stop'
$Root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$Compiler = Join-Path $Root 'src\user\grithl\compiler\gritc.py'
$Source = Join-Path $Root 'src\kernel\grithlk\vfs_fat16_meta.ghl'
$Lib = Join-Path $Root 'src\user\grithl\lib'
$OutDir = Join-Path $Root 'build\test-vfs'
$Asm = Join-Path $OutDir 'vfs_fat16_meta.asm'
$Safety = Join-Path $OutDir 'vfs_fat16_meta.safety.json'

New-Item -Path $OutDir -ItemType Directory -Force | Out-Null
Write-Host 'VFS FAT16 meta: compiling scalar validation firewall...' -ForegroundColor Yellow
& python $Compiler $Source -o $Asm -L $Lib --embed --target kernel --forbid-asm --safety-manifest $Safety
if ($LASTEXITCODE -ne 0) { throw 'vfs_fat16_meta.ghl failed GritHLK compilation' }

$m = Get-Content -Raw -Path $Safety | ConvertFrom-Json
if (@($m.unsafe.declared).Count -ne 0) { throw 'FAT16 metadata validator must remain zero-unsafe' }
if (@($m.unsafe.broad).Count -ne 0) { throw 'FAT16 metadata validator gained broad unsafe authority' }
if (@($m.unsafe.privileged).Count -ne 0) { throw 'FAT16 metadata validator gained privileged unsafe authority' }

$src = Get-Content -Raw -Path $Source
if ($src -notmatch '(?s)fn\s+vfs_fat16_spc_valid\(spc\).*?\(spc\s*&\s*\(spc\s*-\s*1\)\)\s*!=\s*0') {
    throw 'FAT16 sectors-per-cluster power-of-two validation missing'
}
if ($src -notmatch '(?s)fn\s+vfs_fat16_entry_classify\(first_byte,\s*attr\).*?F16_ENTRY_DELETED.*?F16_ATTR_LFN.*?F16_ATTR_VOLUME_ID') {
    throw 'FAT16 directory-entry materialization filters drifted'
}
if ($src -notmatch '(?s)fn\s+vfs_fat16_read_count\(file_size,\s*offset,\s*requested\).*?file_size\s*-\s*offset') {
    throw 'Offset-aware read sizing no longer uses subtraction from validated extent'
}
if ($src -match '(?s)fn\s+vfs_fat16_read_count.*?offset\s*\+\s*requested') {
    throw 'Offset-aware read sizing reintroduced overflow-prone offset+requested arithmetic'
}
if ($src -notmatch '(?s)fn\s+vfs_fat16_clusters_needed\(size,\s*sectors_per_cluster\).*?\(size\s*-\s*1\)\s*/\s*cluster_bytes\s*\+\s*1') {
    throw 'Cluster ceiling calculation no longer avoids size+cluster_bytes overflow'
}

Write-Host 'VFS FAT16 meta: PASS (zero unsafe, strict entry/SPC/cluster/read-range contract).' -ForegroundColor Green
