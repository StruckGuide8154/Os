$ErrorActionPreference = 'Stop'

$NASM = 'C:\Tools\nasm-2.16.03\nasm.exe'
$SRC_DIR = Join-Path $PSScriptRoot 'src'
$BUILD_DIR = Join-Path $PSScriptRoot 'build'
$INCLUDE_DIR = Join-Path $SRC_DIR 'include'
$ESP = Join-Path $BUILD_DIR 'esp\EFI\BOOT'

Write-Host ''
Write-Host '  NexusOS UEFI Build System' -ForegroundColor Cyan
Write-Host '  =========================' -ForegroundColor Cyan
Write-Host ''

New-Item -Path $ESP -ItemType Directory -Force | Out-Null

# 1. Assemble UEFI Loader -> BOOTX64.EFI
Write-Host '[1/2] Assembling UEFI Loader...' -ForegroundColor Yellow
$ErrorActionPreference = 'Continue'
& $NASM -f bin -o "$ESP\BOOTX64.EFI" "$SRC_DIR\boot\uefi_loader.asm" 2>&1 | ForEach-Object { if ($_ -is [System.Management.Automation.ErrorRecord]) { Write-Host "  $_" -ForegroundColor DarkYellow } }
$ErrorActionPreference = 'Stop'
if ($LASTEXITCODE -ne 0) {
    Write-Host '  FAILED' -ForegroundColor Red
    exit 1
}
$sz = (Get-Item "$ESP\BOOTX64.EFI").Length
Write-Host "  OK - BOOTX64.EFI ($sz bytes)" -ForegroundColor Green

# 2. Assemble Kernel -> KERNEL.BIN
Write-Host '[2/2] Assembling Kernel...' -ForegroundColor Yellow
$ErrorActionPreference = 'Continue'
& $NASM -f bin -o "$ESP\KERNEL.BIN" -I "$INCLUDE_DIR\" -I "$SRC_DIR\boot\" "$SRC_DIR\kernel\kernel_build.asm" 2>&1 | ForEach-Object { if ($_ -is [System.Management.Automation.ErrorRecord]) { Write-Host "  $_" -ForegroundColor DarkYellow } }
$ErrorActionPreference = 'Stop'
if ($LASTEXITCODE -ne 0) {
    Write-Host '  FAILED' -ForegroundColor Red
    exit 1
}
$sz = (Get-Item "$ESP\KERNEL.BIN").Length
Write-Host "  OK - KERNEL.BIN ($sz bytes)" -ForegroundColor Green

# 3. Create data disk image with FAT16 filesystem (for ATA PIO access by kernel)
Write-Host '[3/3] Creating FAT16 data disk (data.img)...' -ForegroundColor Yellow
$dataImgPath = Join-Path $BUILD_DIR 'data.img'
$targetSize = 10 * 1024 * 1024   # 10MB
$imgBytes = New-Object byte[] $targetSize

# FAT16 partition starts at sector 320 (same as BIOS layout)
$fatPartStart = 320 * 512
$fatPartSectors = [int](($targetSize - $fatPartStart) / 512)

$bytesPerSect = 512
$sectPerClus = 4
$reservedSects = 1
$numFats = 2
$rootEntries = 512
$rootSectors = ($rootEntries * 32) / $bytesPerSect
$fatEntries = [int](($fatPartSectors - $reservedSects - $rootSectors) / $sectPerClus)
if ($fatEntries -gt 65520) { $fatEntries = 65520 }
$fatSizeSects = [int][Math]::Ceiling(($fatEntries * 2) / $bytesPerSect)
$dataSectors = $fatPartSectors - $reservedSects - ($numFats * $fatSizeSects) - $rootSectors
$totalClusters = [int]($dataSectors / $sectPerClus)

# Write BPB
$bpbOff = $fatPartStart
$imgBytes[$bpbOff + 0] = 0xEB; $imgBytes[$bpbOff + 1] = 0x3C; $imgBytes[$bpbOff + 2] = 0x90
$oem = [System.Text.Encoding]::ASCII.GetBytes("NEXUSOS ")
[Array]::Copy($oem, 0, $imgBytes, $bpbOff + 3, 8)
$imgBytes[$bpbOff + 11] = [byte]($bytesPerSect -band 0xFF)
$imgBytes[$bpbOff + 12] = [byte](($bytesPerSect -shr 8) -band 0xFF)
$imgBytes[$bpbOff + 13] = [byte]$sectPerClus
$imgBytes[$bpbOff + 14] = [byte]($reservedSects -band 0xFF)
$imgBytes[$bpbOff + 15] = [byte](($reservedSects -shr 8) -band 0xFF)
$imgBytes[$bpbOff + 16] = [byte]$numFats
$imgBytes[$bpbOff + 17] = [byte]($rootEntries -band 0xFF)
$imgBytes[$bpbOff + 18] = [byte](($rootEntries -shr 8) -band 0xFF)
if ($fatPartSectors -le 65535) {
    $imgBytes[$bpbOff + 19] = [byte]($fatPartSectors -band 0xFF)
    $imgBytes[$bpbOff + 20] = [byte](($fatPartSectors -shr 8) -band 0xFF)
}
$imgBytes[$bpbOff + 21] = 0xF8
$imgBytes[$bpbOff + 22] = [byte]($fatSizeSects -band 0xFF)
$imgBytes[$bpbOff + 23] = [byte](($fatSizeSects -shr 8) -band 0xFF)
$imgBytes[$bpbOff + 24] = 63; $imgBytes[$bpbOff + 25] = 0
$imgBytes[$bpbOff + 26] = 16; $imgBytes[$bpbOff + 27] = 0
$imgBytes[$bpbOff + 510] = 0x55; $imgBytes[$bpbOff + 511] = 0xAA

# FAT tables
$fat1Off = $fatPartStart + ($reservedSects * $bytesPerSect)
$imgBytes[$fat1Off + 0] = 0xF8; $imgBytes[$fat1Off + 1] = 0xFF
$imgBytes[$fat1Off + 2] = 0xFF; $imgBytes[$fat1Off + 3] = 0xFF
$fat2Off = $fat1Off + ($fatSizeSects * $bytesPerSect)
$rootDirOff = $fat2Off + ($fatSizeSects * $bytesPerSect)
$dataOff = $rootDirOff + ($rootSectors * $bytesPerSect)

function Write-DirEntry($offset, $name, $ext, $attr, $cluster, $size) {
    $nameBytes = [System.Text.Encoding]::ASCII.GetBytes($name.PadRight(8))
    [Array]::Copy($nameBytes, 0, $imgBytes, $offset, 8)
    $extBytes = [System.Text.Encoding]::ASCII.GetBytes($ext.PadRight(3))
    [Array]::Copy($extBytes, 0, $imgBytes, $offset + 8, 3)
    $imgBytes[$offset + 11] = [byte]$attr
    $imgBytes[$offset + 26] = [byte]($cluster -band 0xFF)
    $imgBytes[$offset + 27] = [byte](($cluster -shr 8) -band 0xFF)
    $imgBytes[$offset + 28] = [byte]($size -band 0xFF)
    $imgBytes[$offset + 29] = [byte](($size -shr 8) -band 0xFF)
    $imgBytes[$offset + 30] = [byte](($size -shr 16) -band 0xFF)
    $imgBytes[$offset + 31] = [byte](($size -shr 24) -band 0xFF)
}

$nextFreeCluster = 2
function Write-FileData($data) {
    $bytesWritten = 0
    $firstCluster = $script:nextFreeCluster
    $prevCluster = -1
    $clusterSize = $sectPerClus * $bytesPerSect
    while ($bytesWritten -lt $data.Length) {
        $cluster = $script:nextFreeCluster
        $script:nextFreeCluster++
        if ($prevCluster -ge 2) {
            $fatOff = $fat1Off + ($prevCluster * 2)
            $imgBytes[$fatOff] = [byte]($cluster -band 0xFF)
            $imgBytes[$fatOff + 1] = [byte](($cluster -shr 8) -band 0xFF)
        }
        $clusterOff = $dataOff + (($cluster - 2) * $clusterSize)
        $remaining = $data.Length - $bytesWritten
        $writeLen = [Math]::Min($remaining, $clusterSize)
        [Array]::Copy($data, $bytesWritten, $imgBytes, $clusterOff, $writeLen)
        $bytesWritten += $writeLen
        $prevCluster = $cluster
    }
    if ($prevCluster -ge 2) {
        $fatOff = $fat1Off + ($prevCluster * 2)
        $imgBytes[$fatOff] = 0xFF; $imgBytes[$fatOff + 1] = 0xFF
    }
    return $firstCluster
}

$entryIdx = 0
Write-DirEntry ($rootDirOff + $entryIdx * 32) "NEXUSOS" "   " 0x08 0 0
$entryIdx++

$readmeText = "Welcome to NexusOS v3.0!`r`nThis is a 64-bit operating system written entirely in x86-64 assembly.`r`n`r`nFeatures:`r`n- Graphical desktop environment`r`n- Window manager with drag support`r`n- File explorer with real FAT16 filesystem`r`n- Built-in text editor (Notepad)`r`n- Terminal with basic commands`r`n`r`nEnjoy exploring!`r`n"
$readmeData = [System.Text.Encoding]::ASCII.GetBytes($readmeText)
$readmeCluster = Write-FileData $readmeData
Write-DirEntry ($rootDirOff + $entryIdx * 32) "README" "TXT" 0x20 $readmeCluster $readmeData.Length
$entryIdx++

$helloText = "Hello from NexusOS!`r`nThis file is stored on a real FAT16 filesystem.`r`nYou can edit this in Notepad and save it back.`r`n"
$helloData = [System.Text.Encoding]::ASCII.GetBytes($helloText)
$helloCluster = Write-FileData $helloData
Write-DirEntry ($rootDirOff + $entryIdx * 32) "HELLO" "TXT" 0x20 $helloCluster $helloData.Length
$entryIdx++

$notesText = "My Notes`r`n========`r`n`r`nTODO:`r`n- Learn assembly programming`r`n- Build an OS from scratch`r`n- Add more features`r`n"
$notesData = [System.Text.Encoding]::ASCII.GetBytes($notesText)
$notesCluster = Write-FileData $notesData
Write-DirEntry ($rootDirOff + $entryIdx * 32) "NOTES" "TXT" 0x20 $notesCluster $notesData.Length
$entryIdx++

$sysText = "NexusOS System Information`r`n==========================`r`nKernel: NexusOS v3.0`r`nArch: x86-64`r`nDisplay: 1024x768 32bpp`r`nFS: FAT16`r`n"
$sysData = [System.Text.Encoding]::ASCII.GetBytes($sysText)
$sysCluster = Write-FileData $sysData
Write-DirEntry ($rootDirOff + $entryIdx * 32) "SYSTEM" "TXT" 0x20 $sysCluster $sysData.Length
$entryIdx++

# BMP image
$bmpWidth = 16; $bmpHeight = 16
$bmpRowSize = $bmpWidth * 3
if ($bmpRowSize % 4 -ne 0) { $bmpRowSize += 4 - ($bmpRowSize % 4) }
$bmpDataSize = $bmpRowSize * $bmpHeight
$bmpFileSize = 54 + $bmpDataSize
$bmpData = New-Object byte[] $bmpFileSize
$bmpData[0] = 0x42; $bmpData[1] = 0x4D
$bmpData[2] = [byte]($bmpFileSize -band 0xFF)
$bmpData[3] = [byte](($bmpFileSize -shr 8) -band 0xFF)
$bmpData[10] = 54; $bmpData[14] = 40
$bmpData[18] = [byte]$bmpWidth; $bmpData[22] = [byte]$bmpHeight
$bmpData[26] = 1; $bmpData[28] = 24
for ($y = 0; $y -lt $bmpHeight; $y++) {
    for ($x = 0; $x -lt $bmpWidth; $x++) {
        $off = 54 + ($y * $bmpRowSize) + ($x * 3)
        $bmpData[$off] = 0xFF; $bmpData[$off+1] = 0xFF; $bmpData[$off+2] = 0xFF
        if ($x -eq 0 -or $x -eq 15 -or $y -eq 0 -or $y -eq 15) {
            $bmpData[$off] = 0xAA; $bmpData[$off+1] = 0x55; $bmpData[$off+2] = 0x00
        }
        if ($y -ge 3 -and $y -le 12 -and $x -ge 3 -and $x -le 12) {
            if ($x -eq 3 -or $x -eq 12 -or ($x - 3) -eq (12 - $y)) {
                $bmpData[$off] = 0x00; $bmpData[$off+1] = 0x88; $bmpData[$off+2] = 0x00
            }
        }
    }
}
$logoCluster = Write-FileData $bmpData
Write-DirEntry ($rootDirOff + $entryIdx * 32) "LOGO" "BMP" 0x20 $logoCluster $bmpData.Length
$entryIdx++

# Copy FAT1 to FAT2
[Array]::Copy($imgBytes, $fat1Off, $imgBytes, $fat2Off, $fatSizeSects * $bytesPerSect)

[System.IO.File]::WriteAllBytes($dataImgPath, $imgBytes)
Write-Host "  OK - data.img ($totalClusters clusters, $($entryIdx - 1) files)" -ForegroundColor Green

Write-Host ''
Write-Host '  BUILD SUCCESSFUL' -ForegroundColor Green
Write-Host ''
Write-Host "  Output: $ESP\" -ForegroundColor White
Write-Host '    BOOTX64.EFI  (UEFI bootloader)' -ForegroundColor Gray
Write-Host '    KERNEL.BIN   (NexusOS kernel)' -ForegroundColor Gray
Write-Host "    $dataImgPath  (FAT16 data disk)" -ForegroundColor Gray
Write-Host ''
