# GritHL build hook.
# Compiles every *.ghl under src/user/grithl/apps to build/ghl/*.asm.
# Does NOT touch the kernel build. Integration into apps.asm is an explicit
# opt-in step handled by whoever wants to wire a HL app into the image.

param(
    [switch]$Release,
    [switch]$Verify = $true,
    [switch]$O0,
    [switch]$O2
)

$ErrorActionPreference = 'Stop'
$Root = Resolve-Path (Join-Path $PSScriptRoot '..\..')

$NASM = 'C:\Tools\nasm-2.16.03\nasm.exe'
$PY   = 'python'
$ROOT = $Root
$COMPILER = Join-Path $ROOT 'src\user\grithl\compiler\gritc.py'
$APP_DIR  = Join-Path $ROOT 'src\user\grithl\apps'
$LIB_DIR  = Join-Path $ROOT 'src\user\grithl\lib'
$OUT_DIR  = Join-Path $ROOT 'build\ghl'
$ManifestPath = Join-Path $OUT_DIR 'manifest.json'
$IncludePath  = Join-Path $OUT_DIR 'generated_apps.inc'
New-Item -Path $OUT_DIR -ItemType Directory -Force | Out-Null

Write-Host ''
Write-Host '  GritHL Build' -ForegroundColor Cyan
Write-Host '  =============' -ForegroundColor Cyan
Write-Host ("  Mode: " + ($(if ($Release) { 'release' } else { 'debug' }))) -ForegroundColor DarkGray
Write-Host ("  Opt:  " + ($(if ($O0) { 'O0' } elseif ($O2) { 'O2' } else { 'O1' }))) -ForegroundColor DarkGray

$count = 0
$manifestApps = @()
$includeLines = @(
    '; GritHL generated app include - do not edit by hand',
    '; Produced by build_ghl.ps1 before kernel assembly.'
)
Get-ChildItem -Path $APP_DIR -Filter '*.ghl' | ForEach-Object {
    $in = $_.FullName
    $name = [IO.Path]::GetFileNameWithoutExtension($_.Name)
    if ($Release -and $name -in @('hello')) {
        Write-Host "  skip $name.ghl (debug/test app)" -ForegroundColor DarkGray
        return
    }
    $asm = Join-Path $OUT_DIR ($name + '.asm')
    Write-Host "  compile $name.ghl -> $name.asm" -ForegroundColor Yellow
    # Embed mode: strips bits/default/section so the output can be %include'd
    # directly from apps.asm without fighting the kernel's section layout.
    $CompilerArgs = @($in, '-o', $asm, '-L', $LIB_DIR, '--prefix', $name, '--embed', '--emit-sigs')
    if ($O0) { $CompilerArgs += '--O0' }
    if ($O2) { $CompilerArgs += '--O2' }
    & $PY $COMPILER @CompilerArgs
    if ($LASTEXITCODE -ne 0) { Write-Host '    FAILED compile' -ForegroundColor Red; exit 1 }
    $sz = (Get-Item $asm).Length
    Write-Host "    OK ($sz bytes .asm)" -ForegroundColor Green
    $prefix = "app_hl_$name"
    $manifestApps += [pscustomobject]@{
        name = $name
        source = ("src/user/grithl/apps/{0}.ghl" -f $name)
        asm = ("build/ghl/{0}.asm" -f $name)
        prefix = $prefix
        draw = ("{0}_draw" -f $prefix)
        click = ("{0}_click" -f $prefix)
        key = ("{0}_key" -f $prefix)
    }
    # Per-app integrity manifest (docs/per-app-integrity-manifest.md): wrap each
    # app's bytes between app_seg_<name>_start/_end labels so apps.asm's
    # APP_MANIFEST_ENTRY can record/measure the segment.
    $includeLines += ('app_seg_{0}_start:' -f $name)
    $includeLines += ('%include "build/ghl/{0}.asm"' -f $name)
    $includeLines += ('app_seg_{0}_end:' -f $name)
    $count++
}

$manifest = [pscustomobject]@{
    sdk = 'GritHL'
    generatedBy = 'build_ghl.ps1'
    apps = $manifestApps
}
$ascii = [System.Text.Encoding]::ASCII
[System.IO.File]::WriteAllBytes($ManifestPath, $ascii.GetBytes((($manifest | ConvertTo-Json -Depth 5) + [Environment]::NewLine)))
[System.IO.File]::WriteAllBytes($IncludePath, $ascii.GetBytes((($includeLines -join [Environment]::NewLine) + [Environment]::NewLine)))

Write-Host "  Built $count unit(s)." -ForegroundColor Green
Write-Host "  SDK manifest: $ManifestPath" -ForegroundColor DarkGray
Write-Host "  SDK include:  $IncludePath" -ForegroundColor DarkGray

$RegistryTool = Join-Path $ROOT 'tools\build_sig_registry.py'
if (Test-Path $RegistryTool) {
    & $PY $RegistryTool
    if ($LASTEXITCODE -ne 0) { Write-Host '  FAILED signature registry' -ForegroundColor Red; exit 1 }
    Write-Host "  Signature registry: $(Join-Path $ROOT 'build\sig_registry.json')" -ForegroundColor DarkGray
}

$CoverageTool = Join-Path $ROOT 'tools\check_coverage.py'
if (Test-Path $CoverageTool) {
    & $PY $CoverageTool
    if ($LASTEXITCODE -ne 0) { Write-Host '  FAILED signature coverage' -ForegroundColor Red; exit 1 }
}
