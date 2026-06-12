# ============================================================================
# build_shaders.ps1 - compile AMDGCN shader sources to embedded blobs.
#
# Inputs  : tools/gpu/shaders/*.s         (hand-written GFX11 assembly)
# Outputs : src/resources/gpu/*.bin       (raw .text payload, ramdisk-ready)
#           build/gpu/*.o                 (intermediate ELF)
#           build/gpu/*.dis               (llvm-objdump disassembly for review)
#
# Toolchain requirement: LLVM >= 17 with the AMDGPU target built in.
# The script does NOT auto-install LLVM. If clang/llvm-objdump/llvm-objcopy
# are missing it prints what to install and exits non-zero so CI surfaces it.
# This keeps the main build (build_uefi.ps1) independent of LLVM - shader
# blobs are pre-built and checked in.
#
# Future-proofing:
#   * Each .s file is compiled independently. Add new shaders by dropping
#     them into shaders/ - the loop picks them up.
#   * GPU target ($Mcpu) is a parameter; flip to gfx1151 etc. without
#     touching this script.
#   * Disassembly is always produced so reviewers can verify against the
#     spec without re-running the toolchain.
# ============================================================================

param(
    [string]$Mcpu = 'gfx1150',
    [string]$ShaderDir = (Join-Path $PSScriptRoot 'shaders'),
    [string]$BuildDir  = (Join-Path $PSScriptRoot '..\..\build\gpu'),
    [string]$OutDir    = (Join-Path $PSScriptRoot '..\..\src\resources\gpu')
)

$ErrorActionPreference = 'Stop'

function Require-Tool($name) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if (-not $cmd) {
        Write-Error @"
Missing tool: $name

Install LLVM >= 17 with AMDGPU target. On Windows:
  winget install LLVM.LLVM
On Linux:
  apt install clang llvm  (Debian/Ubuntu)
"@
        exit 2
    }
    return $cmd.Source
}

$clang   = Require-Tool 'clang'
$objcopy = Require-Tool 'llvm-objcopy'
$objdump = Require-Tool 'llvm-objdump'

if (-not (Test-Path $BuildDir)) { New-Item -ItemType Directory -Path $BuildDir | Out-Null }
if (-not (Test-Path $OutDir))   { New-Item -ItemType Directory -Path $OutDir   | Out-Null }

$sources = Get-ChildItem -Path $ShaderDir -Filter '*.s'
if ($sources.Count -eq 0) {
    Write-Warning "No .s files found in $ShaderDir"
    exit 0
}

foreach ($src in $sources) {
    $stem = [System.IO.Path]::GetFileNameWithoutExtension($src.Name)
    $obj  = Join-Path $BuildDir "$stem.o"
    $bin  = Join-Path $OutDir   "$stem.bin"
    $dis  = Join-Path $BuildDir "$stem.dis"

    Write-Host "[shader] $($src.Name) -> $stem.bin"

    & $clang `
        -x assembler-with-cpp `
        -target amdgcn-amd-amdpal `
        "-mcpu=$Mcpu" `
        -mcode-object-version=5 `
        -c $src.FullName `
        -o $obj
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    & $objcopy -O binary --only-section=.text $obj $bin
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    & $objdump -d "--mcpu=$Mcpu" $obj | Set-Content -Encoding utf8 $dis
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

    $size = (Get-Item $bin).Length
    Write-Host "    $size bytes  ($bin)"
}

Write-Host "Done. Disassemblies in $BuildDir for review."
