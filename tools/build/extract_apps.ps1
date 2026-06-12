param(
    [string]$KernelPath,
    [string]$OutPath,
    [switch]$StripFromKernel
)
$ErrorActionPreference = 'Stop'

$startMarker = [byte[]](0x47, 0x52, 0x41, 0x50, 0x50, 0x42, 0x4C, 0x4F,
                        0x42, 0x53, 0x54, 0x52, 0x54, 0xDE, 0xAD, 0xBE)
$endMarker   = [byte[]](0x47, 0x52, 0x41, 0x50, 0x50, 0x42, 0x4C, 0x4F,
                        0x42, 0x45, 0x4E, 0x44, 0x21, 0xCA, 0xFE, 0xBE)

function Find-Marker([byte[]]$Hay, [byte[]]$Needle, [int]$StartAt = 0) {
    for ($i = $StartAt; $i -le $Hay.Length - $Needle.Length; $i++) {
        $match = $true
        for ($j = 0; $j -lt $Needle.Length; $j++) {
            if ($Hay[$i + $j] -ne $Needle[$j]) { $match = $false; break }
        }
        if ($match) { return $i }
    }
    return -1
}

$bytes = [System.IO.File]::ReadAllBytes($KernelPath)
$startIdx = Find-Marker $bytes $startMarker 0
if ($startIdx -lt 0) { throw "App blob start marker not found in $KernelPath" }
$endIdx = Find-Marker $bytes $endMarker ($startIdx + $startMarker.Length)
if ($endIdx -lt 0) { throw "App blob end marker not found in $KernelPath" }

# Blob bytes include BOTH sentinels: the start marker so internal RIP-relative
# calls preserve the same layout after the blob is copied into a slot, and the
# end marker so APPS.BIN is byte-for-byte the embedded [app_blob_start,
# app_blob_end) the KASLR path runs. Keeping the two identical means the user-
# blob signature (security_todo.md §9, crypto.ghl) covers the same
# extent on both the KASLR (embedded) and non-KASLR (APPS.BIN) runtime paths.
# The trailing 16-byte end sentinel is inert data past all blob code/data.
$blobStart = $startIdx
$blobEnd   = $endIdx + $endMarker.Length
$blobLen   = $blobEnd - $blobStart

$blob = New-Object byte[] $blobLen
[Array]::Copy($bytes, $blobStart, $blob, 0, $blobLen)
[System.IO.File]::WriteAllBytes($OutPath, $blob)
Write-Host ("  extracted APPS.BIN ({0} bytes, kernel offset 0x{1:X})" -f $blobLen, $blobStart)

if ($StripFromKernel) {
    # Zero out the whole range (including sentinels) so kernel.bin no longer
    # contains the app code. The kernel reads the blob exclusively from the
    # loaded APPS.BIN at runtime.
    $stripFrom = $startIdx
    $stripTo   = $endIdx + $endMarker.Length
    for ($i = $stripFrom; $i -lt $stripTo; $i++) { $bytes[$i] = 0 }
    [System.IO.File]::WriteAllBytes($KernelPath, $bytes)
    Write-Host ("  stripped {0} bytes (offset 0x{1:X}..0x{2:X}) from kernel.bin" -f ($stripTo-$stripFrom), $stripFrom, $stripTo)
}
