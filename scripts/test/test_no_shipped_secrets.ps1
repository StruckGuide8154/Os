$ErrorActionPreference = 'Stop'

$Root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$Guard = Join-Path $Root 'tools\security\check_no_shipped_secrets.ps1'
$Temp = Join-Path ([System.IO.Path]::GetTempPath()) ('grit-secret-scan-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Temp | Out-Null

try {
    $secret = [byte[]](0x51, 0x52, 0x4E, 0x47, 0x00, 0xA5, 0x5A, 0xFF)
    $secretPath = Join-Path $Temp 'secret.bin'
    $cleanPath = Join-Path $Temp 'clean.bin'
    $leakPath = Join-Path $Temp 'leak.bin'
    [System.IO.File]::WriteAllBytes($secretPath, $secret)
    [System.IO.File]::WriteAllBytes($cleanPath, [byte[]](1, 2, 3, 4, 5, 6, 7, 8, 9))
    [System.IO.File]::WriteAllBytes($leakPath, [byte[]](1, 2, 3) + $secret + [byte[]](4, 5, 6))

    & powershell -NoProfile -ExecutionPolicy Bypass -File $Guard -ArtifactPath $cleanPath -SecretPath $secretPath
    if ($LASTEXITCODE -ne 0) { throw 'Clean artifact was rejected.' }

    & powershell -NoProfile -ExecutionPolicy Bypass -File $Guard -ArtifactPath $leakPath -SecretPath $secretPath
    if ($LASTEXITCODE -eq 0) { throw 'Planted private bytes were not detected.' }

    Write-Host '[no-shipped-secrets-test] PASS' -ForegroundColor Green
}
finally {
    Remove-Item -LiteralPath $Temp -Recurse -Force -ErrorAction SilentlyContinue
}
