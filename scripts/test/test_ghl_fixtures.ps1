$ErrorActionPreference = 'Stop'

$Root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$Compiler = Join-Path $Root 'src\user\grithl\compiler\gritc.py'
$LibDir = Join-Path $Root 'src\user\grithl\lib'
$TestDir = Join-Path $Root 'tests\ghl'
$OutDir = Join-Path $Root 'build\ghl\tests'

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

Get-ChildItem -Path $TestDir -Filter '*.ghl' | ForEach-Object {
    $name = [IO.Path]::GetFileNameWithoutExtension($_.Name)
    $out = Join-Path $OutDir ($name + '.asm')
    Write-Host "[ghl-fixture] compile $($_.Name)" -ForegroundColor Yellow
    python $Compiler $_.FullName -o $out -L $LibDir --prefix "test_$name" --embed --emit-sigs
    if ($LASTEXITCODE -ne 0) {
        throw "GritHL fixture compile failed: $($_.Name)"
    }
}

Write-Host '[ghl-fixture] PASS' -ForegroundColor Green
