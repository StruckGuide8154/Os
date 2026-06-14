param(
    [Parameter(Mandatory = $true)][string]$ArtifactPath,
    [Parameter(Mandatory = $true)][string]$SecretPath
)

$ErrorActionPreference = 'Stop'

function Find-Bytes {
    param([byte[]]$Haystack, [byte[]]$Needle)
    if ($Needle.Length -eq 0 -or $Haystack.Length -lt $Needle.Length) { return -1 }
    for ($i = 0; $i -le $Haystack.Length - $Needle.Length; $i++) {
        $match = $true
        for ($j = 0; $j -lt $Needle.Length; $j++) {
            if ($Haystack[$i + $j] -ne $Needle[$j]) { $match = $false; break }
        }
        if ($match) { return $i }
    }
    return -1
}

$artifactPathResolved = (Resolve-Path $ArtifactPath).ProviderPath
$secretPathResolved = (Resolve-Path $SecretPath).ProviderPath
$artifact = [System.IO.File]::ReadAllBytes($artifactPathResolved)
$secret = [System.IO.File]::ReadAllBytes($secretPathResolved)
$chunkBytes = [Math]::Min(32, $secret.Length)
for ($secretOffset = 0; $secretOffset -le $secret.Length - $chunkBytes; $secretOffset += $chunkBytes) {
    $chunk = New-Object byte[] $chunkBytes
    [Array]::Copy($secret, $secretOffset, $chunk, 0, $chunkBytes)
    $artifactOffset = Find-Bytes -Haystack $artifact -Needle $chunk
    if ($artifactOffset -ge 0) {
        Write-Host ("[no-shipped-secrets] FAIL: {0}-byte private fragment at artifact offset 0x{1} (secret offset 0x{2})" -f `
            $chunkBytes, $artifactOffset.ToString('x'), $secretOffset.ToString('x'))
        exit 1
    }
}

Write-Host "[no-shipped-secrets] PASS: no private fragment of $chunkBytes bytes found; only a public commitment may ship."
exit 0
