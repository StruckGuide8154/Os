# Compile/security gate for the VFS policy core.
# This intentionally does not boot QEMU: Phase 1 must first prove that the
# security policy kernel is valid GritHLK and requires zero unsafe privileges.

$ErrorActionPreference = 'Stop'
$Root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$Compiler = Join-Path $Root 'src\user\grithl\compiler\gritc.py'
$Source = Join-Path $Root 'src\kernel\grithlk\vfs_core.ghl'
$Lib = Join-Path $Root 'src\user\grithl\lib'
$OutDir = Join-Path $Root 'build\test-vfs'
$Asm = Join-Path $OutDir 'vfs_core.asm'
$Safety = Join-Path $OutDir 'vfs_core.safety.json'

New-Item -Path $OutDir -ItemType Directory -Force | Out-Null

if (-not (Test-Path $Source)) { throw 'Missing src/kernel/grithlk/vfs_core.ghl' }
if (-not (Test-Path $Compiler)) { throw 'Missing GritHL compiler' }

Write-Host 'VFS contract: compiling zero-unsafe policy core...' -ForegroundColor Yellow
& python $Compiler $Source -o $Asm -L $Lib --embed --target kernel --forbid-asm --safety-manifest $Safety
if ($LASTEXITCODE -ne 0) { throw 'vfs_core.ghl failed GritHLK compilation' }
if (-not (Test-Path $Safety)) { throw 'Missing VFS safety manifest' }

$m = Get-Content -Raw -Path $Safety | ConvertFrom-Json
$declared = @($m.unsafe.declared)
$broad = @($m.unsafe.broad)
$privileged = @($m.unsafe.privileged)
if ($declared.Count -ne 0) { throw "VFS policy core declares unsafe capabilities: $($declared | ConvertTo-Json -Compress)" }
if ($broad.Count -ne 0) { throw 'VFS policy core uses a broad unsafe override' }
if ($privileged.Count -ne 0) { throw 'VFS policy core uses a privileged unsafe override' }

$src = Get-Content -Raw -Path $Source
$requiredGlobals = @(
    'vfs_core_abi_version',
    'vfs_rights_valid',
    'vfs_rights_subset',
    'vfs_rights_attenuate',
    'vfs_mount_allows',
    'vfs_open_flags_valid',
    'vfs_open_required_rights',
    'vfs_checked_add_ok',
    'vfs_checked_mul_ok',
    'vfs_range_valid'
)
foreach ($name in $requiredGlobals) {
    if ($src -notmatch ('(?m)^global\s+' + [regex]::Escape($name) + ';')) {
        throw "VFS contract global missing: $name"
    }
}

# Structural guards for the no-amplification design. These are intentionally
# narrow source guards in addition to compiler safety metadata.
if ($src -match '(?m)^\s*unsafe\s+') { throw 'VFS policy core must remain zero-unsafe' }
if ($src -match 'VFS_R_(ADMIN|ROOT|SUPERUSER|BYPASS)') { throw 'Ambient/bypass VFS right introduced' }
if ($src -notmatch 'let\s+out\s*=\s*parent\s*&\s*requested') { throw 'Rights attenuation no longer starts from parent & requested' }
if ($src -notmatch 'VFS_M_RDONLY') { throw 'Read-only mount policy missing' }
if ($src -notmatch 'VFS_PATH_MAX\s*=\s*1024') { throw 'Canonical VFS path bound drifted' }
if ($src -notmatch 'VFS_NAME_MAX\s*=\s*255') { throw 'Canonical VFS component bound drifted' }

Write-Host 'VFS contract: PASS (compiles --forbid-asm; zero unsafe; rights/path guards intact).' -ForegroundColor Green
