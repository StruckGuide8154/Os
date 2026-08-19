# Compile/security gate for the canonical kernel-snapshot path iterator.

$ErrorActionPreference = 'Stop'
$Root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$Compiler = Join-Path $Root 'src\user\grithl\compiler\gritc.py'
$Source = Join-Path $Root 'src\kernel\grithlk\vfs_path.ghl'
$Lib = Join-Path $Root 'src\user\grithl\lib'
$OutDir = Join-Path $Root 'build\test-vfs'
$Asm = Join-Path $OutDir 'vfs_path.asm'
$Safety = Join-Path $OutDir 'vfs_path.safety.json'

New-Item -Path $OutDir -ItemType Directory -Force | Out-Null
Write-Host 'VFS path: compiling canonical iterator...' -ForegroundColor Yellow
& python $Compiler $Source -o $Asm -L $Lib --embed --target kernel --forbid-asm --safety-manifest $Safety
if ($LASTEXITCODE -ne 0) { throw 'vfs_path.ghl failed GritHLK compilation' }

$m = Get-Content -Raw -Path $Safety | ConvertFrom-Json
$declared = @($m.unsafe.declared | ForEach-Object { if ($null -ne $_.cap) { [string]$_.cap } else { [string]$_ } } | Sort-Object)
if (($declared -join ',') -ne 'raw_mem') {
    throw "VFS path unsafe surface drifted: expected only raw_mem, got [$($declared -join ', ')]"
}
if (@($m.unsafe.privileged).Count -ne 0) { throw 'VFS path gained privileged unsafe authority' }

$src = Get-Content -Raw -Path $Source
if ($src -match '(?m)^\s*unsafe\s+(user_mem|implicit_extern|asm|raw_io|syscall|kernel_priv|kernel_io)\b') {
    throw 'VFS path iterator gained authority beyond reading a kernel snapshot'
}
if ($src -notmatch 'const\s+VFS_PATH_MAX\s*=\s*1024;') { throw 'VFS path bound drifted' }
if ($src -notmatch 'const\s+VFS_NAME_MAX\s*=\s*255;') { throw 'VFS component bound drifted' }
if ($src -notmatch '(?s)fn\s+vfs_path_next\(buf,\s*length,\s*cursor\).*?if\s+ch\s*==\s*0\s*\{\s*return\s+VFS_PATH_INVALID;') {
    throw 'Embedded-NUL rejection missing from VFS path iterator'
}
if ($src -notmatch '(?s)fn\s+vfs_path_next\(buf,\s*length,\s*cursor\).*?if\s+n\s*>\s*VFS_NAME_MAX\s*\{\s*return\s+VFS_PATH_INVALID;') {
    throw 'Component-length fail-closed bound missing'
}
if ($src -notmatch '(?s)if\s+n\s*==\s*2\s*\{.*?VFS_COMP_PARENT') {
    throw 'Structural parent-component classification missing'
}
if ($src -match '(?m)^\s*(malloc|alloc|heap_)') {
    throw 'Canonical path iterator unexpectedly allocates'
}

Write-Host 'VFS path: PASS (kernel snapshot only, bounded components, structural dot/dotdot, no allocation).' -ForegroundColor Green
