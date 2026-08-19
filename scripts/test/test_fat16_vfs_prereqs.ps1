# Runtime-source/compile gate for FAT16 prerequisites that VFS backend #1 relies on.
# This deliberately tests the legacy/current FAT16 implementation before the VFS
# adapter is allowed to call it, so unsafe semantics cannot be blessed by wrapping.

$ErrorActionPreference = 'Stop'
$Root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$Compiler = Join-Path $Root 'src\user\grithl\compiler\gritc.py'
$Source = Join-Path $Root 'src\kernel\grithlk\fat16_core.ghl'
$Lib = Join-Path $Root 'src\user\grithl\lib'
$OutDir = Join-Path $Root 'build\test-vfs'
$Asm = Join-Path $OutDir 'fat16_core.vfs-prereq.asm'
$Safety = Join-Path $OutDir 'fat16_core.vfs-prereq.safety.json'

New-Item -Path $OutDir -ItemType Directory -Force | Out-Null
Write-Host 'FAT16 VFS prereqs: compiling current backend...' -ForegroundColor Yellow
& python $Compiler $Source -o $Asm -L $Lib --embed --target kernel --forbid-asm --safety-manifest $Safety
if ($LASTEXITCODE -ne 0) { throw 'fat16_core.ghl failed GritHLK compilation' }

$m = Get-Content -Raw -Path $Safety | ConvertFrom-Json
$declared = @($m.unsafe.declared | ForEach-Object { if ($null -ne $_.cap) { [string]$_.cap } else { [string]$_ } } | Sort-Object)
$expected = @('implicit_extern','raw_mem')
if (($declared -join ',') -ne ($expected -join ',')) {
    throw "FAT16 unsafe capability surface drifted: [$($declared -join ', ')]"
}
if (@($m.unsafe.privileged).Count -ne 0) { throw 'FAT16 gained privileged unsafe authority' }

$src = Get-Content -Raw -Path $Source

if ($src -notmatch '(?m)^const\s+BAD_CLUSTER\s*=\s*0xFFF7;') {
    throw 'FAT16 BAD cluster marker is not explicitly defined'
}
if ($src -notmatch '(?s)fn\s+f16_cluster_lba\(cluster\).*?cluster\s*==\s*BAD_CLUSTER\s*\{\s*return\s+0;') {
    throw 'FAT16 LBA conversion still admits the BAD cluster marker'
}
if ($src -notmatch '(?s)fn\s+f16_parse_bpb\(\).*?\(spc\s*&\s*\(spc\s*-\s*1\)\)\s*!=\s*0\s*\{\s*return\s+-1;') {
    throw 'FAT16 BPB parser does not require power-of-two sectors/cluster'
}
if ($src -notmatch '(?s)fn\s+fat16_flush_fats\(\).*?if\s+ata_write_sectors\(.*?\)\s*!=\s*0\s*\{\s*rc\s*=\s*-1;') {
    throw 'FAT16 FAT flush still discards device write failure'
}
if ($src -notmatch '(?s)fn\s+fat16_flush_current_dir\(\).*?if\s+ata_write_sectors\(.*?\)\s*!=\s*0\s*\{\s*return\s+-1;') {
    throw 'FAT16 directory flush still discards device write failure'
}
if ($src -notmatch '(?s)fn\s+f16_change_dir_load\(cluster\).*?if\s+ata_read_sectors\(lba,\s*dst\s*\+\s*total,\s*spc\)\s*!=\s*0\s*\{\s*return\s+-1;') {
    throw 'Subdirectory materialization still accepts a failed partial read'
}
if ($src -notmatch '(?s)fn\s+f16_change_dir_load\(cluster\).*?if\s+total\s*\+\s*bytes\s*>\s*ROOT_CACHE_BYTES\s*\{\s*return\s+-1;') {
    throw 'Oversized subdirectory is still truncated instead of rejected'
}
if ($src -notmatch '(?s)fn\s+fat16_switch_to\(r15\s+slot\).*?let\s+rc\s*=\s*fat16_change_dir\(cwd\);.*?if\s+rc\s*!=\s*0\s*\{\s*return\s+rc;\}.*?sw\(&fat16_cache_owner,\s*s\);') {
    throw 'Cache ownership can still publish after failed slot cwd materialization'
}
if ($src -notmatch '(?s)fn\s+f16_find_free_cluster\(start\).*?if\s+cl\s*>=\s*fe\s*\{\s*cl\s*=\s*2;\}.*?remaining\s*=\s*remaining\s*-\s*1;') {
    throw 'Free-cluster search is not bounded wraparound'
}
if ($src -notmatch '(?s)fn\s+fat16_read_file\(ent,\s*dst,\s*max_bytes\).*?ata_read_sectors\(lba,\s*&fat16_file_buf,\s*spc\)\s*!=\s*0\s*\{\s*return\s+-1;') {
    throw 'File read still converts a device failure into a short success'
}

Write-Host 'FAT16 VFS prereqs: PASS (bad-cluster, geometry, I/O propagation, complete cache loads, bounded allocation).' -ForegroundColor Green
