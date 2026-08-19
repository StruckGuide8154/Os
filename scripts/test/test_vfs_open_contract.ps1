# Compile/security gate for the zero-unsafe VFS open-intent firewall.

$ErrorActionPreference = 'Stop'
$Root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$Compiler = Join-Path $Root 'src\user\grithl\compiler\gritc.py'
$Source = Join-Path $Root 'src\kernel\grithlk\vfs_open.ghl'
$Lib = Join-Path $Root 'src\user\grithl\lib'
$OutDir = Join-Path $Root 'build\test-vfs'
$Asm = Join-Path $OutDir 'vfs_open.asm'
$Safety = Join-Path $OutDir 'vfs_open.safety.json'

New-Item -Path $OutDir -ItemType Directory -Force | Out-Null
Write-Host 'VFS open: compiling zero-unsafe open authority firewall...' -ForegroundColor Yellow
& python $Compiler $Source -o $Asm -L $Lib --embed --target kernel --forbid-asm --safety-manifest $Safety
if ($LASTEXITCODE -ne 0) { throw 'vfs_open.ghl failed GritHLK compilation' }

$m = Get-Content -Raw -Path $Safety | ConvertFrom-Json
if (@($m.unsafe.declared).Count -ne 0) { throw 'VFS open authority firewall must remain zero-unsafe' }
if (@($m.unsafe.broad).Count -ne 0) { throw 'VFS open authority firewall gained broad unsafe authority' }
if (@($m.unsafe.privileged).Count -ne 0) { throw 'VFS open authority firewall gained privileged unsafe authority' }

$src = Get-Content -Raw -Path $Source
if ($src -notmatch '(?s)fn\s+vfs_open_rights_cover_flags\(flags,\s*rights\).*?vfs_open_required_rights\(flags\).*?vfs_rights_subset\(rights,\s*required\)\s*==\s*0') {
    throw 'Open flags are no longer structurally covered by immutable file rights'
}
if ($src -notmatch '(?s)fn\s+vfs_open_object_checked\(.*?vfs_open_rights_cover_flags\(flags,\s*rights\)\s*==\s*0\s*\{\s*return\s+0;.*?vfs_file_open_object') {
    throw 'Canonical backend open can bypass the open-rights firewall'
}
if ($src -notmatch '(?s)fn\s+vfs_open_existing_checked\(.*?vfs_open_rights_cover_flags\(flags,\s*rights\)\s*==\s*0\s*\{\s*return\s+0;.*?vfs_file_alloc') {
    throw 'Existing-node open can bypass the open-rights firewall'
}

Write-Host 'VFS open: PASS (zero unsafe; open flags cannot exceed immutable rights).' -ForegroundColor Green
