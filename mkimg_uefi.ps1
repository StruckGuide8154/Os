$ErrorActionPreference = 'Stop'

$BUILD = Join-Path $PSScriptRoot 'build'
$ESP = Join-Path $BUILD 'esp'
$IMG = Join-Path $BUILD 'nexus_uefi.img'
$BOOTX64 = Join-Path $ESP 'EFI\BOOT\BOOTX64.EFI'
$KERNEL = Join-Path $ESP 'EFI\BOOT\KERNEL.BIN'

Write-Host ''
Write-Host '  NexusOS UEFI Disk Image Builder' -ForegroundColor Cyan
Write-Host '  ================================' -ForegroundColor Cyan
Write-Host ''

if (-not (Test-Path $BOOTX64) -or -not (Test-Path $KERNEL)) {
    Write-Host '  ERROR: Run build_uefi.ps1 first!' -ForegroundColor Red
    exit 1
}

$efiSize = (Get-Item $BOOTX64).Length
$kernSize = (Get-Item $KERNEL).Length
Write-Host "  BOOTX64.EFI: $efiSize bytes" -ForegroundColor Gray
Write-Host "  KERNEL.BIN:  $kernSize bytes" -ForegroundColor Gray

# --- Create a 64MB GPT disk with a single EFI System Partition ---
# Layout:
#   LBA 0:        Protective MBR
#   LBA 1:        GPT Header
#   LBA 2-33:     GPT Partition Entries (128 bytes each, 128 entries)
#   LBA 34:       EFI System Partition starts (FAT32)
#   ...
#   LBA 131038:   EFI System Partition ends
#   LBA 131039-70: Backup GPT entries
#   LBA 131071:   Backup GPT header
# Total: 131072 sectors * 512 = 64MB

$sectorSize = 512
$totalSectors = 131072  # 64MB
$partStartLBA = 2048    # Standard alignment
$partEndLBA = $totalSectors - 2048  # Leave space for backup GPT
$partSectors = $partEndLBA - $partStartLBA

Write-Host "  Creating ${totalSectors} sector (64MB) disk image..." -ForegroundColor Yellow

# Create empty image
$imgBytes = New-Object byte[] ($totalSectors * $sectorSize)

# === PROTECTIVE MBR (LBA 0) ===
# Boot signature
$imgBytes[510] = 0x55
$imgBytes[511] = 0xAA
# Partition entry 1 at offset 446 (protective MBR for GPT)
$imgBytes[446] = 0x00       # Not bootable
$imgBytes[447] = 0x00; $imgBytes[448] = 0x02; $imgBytes[449] = 0x00  # CHS start
$imgBytes[450] = 0xEE       # GPT protective type
$imgBytes[451] = 0xFF; $imgBytes[452] = 0xFF; $imgBytes[453] = 0xFF  # CHS end
# LBA start = 1
$imgBytes[454] = 0x01; $imgBytes[455] = 0x00; $imgBytes[456] = 0x00; $imgBytes[457] = 0x00
# LBA size = totalSectors - 1
$sz = $totalSectors - 1
$imgBytes[458] = [byte]($sz -band 0xFF)
$imgBytes[459] = [byte](($sz -shr 8) -band 0xFF)
$imgBytes[460] = [byte](($sz -shr 16) -band 0xFF)
$imgBytes[461] = [byte](($sz -shr 24) -band 0xFF)

# === GPT HEADER (LBA 1) ===
$gptOff = $sectorSize  # 512
# Signature "EFI PART"
[System.Text.Encoding]::ASCII.GetBytes('EFI PART').CopyTo($imgBytes, $gptOff)
# Revision 1.0
$imgBytes[$gptOff + 8] = 0x00; $imgBytes[$gptOff + 9] = 0x00
$imgBytes[$gptOff + 10] = 0x01; $imgBytes[$gptOff + 11] = 0x00
# Header size = 92
$imgBytes[$gptOff + 12] = 92; $imgBytes[$gptOff + 13] = 0; $imgBytes[$gptOff + 14] = 0; $imgBytes[$gptOff + 15] = 0
# CRC32 of header (filled later)
# Reserved = 0 (bytes 20-23)
# My LBA = 1
$imgBytes[$gptOff + 24] = 1
# Alternate LBA = last sector
$alt = $totalSectors - 1
$imgBytes[$gptOff + 32] = [byte]($alt -band 0xFF)
$imgBytes[$gptOff + 33] = [byte](($alt -shr 8) -band 0xFF)
$imgBytes[$gptOff + 34] = [byte](($alt -shr 16) -band 0xFF)
$imgBytes[$gptOff + 35] = [byte](($alt -shr 24) -band 0xFF)
# First usable LBA = 34
$imgBytes[$gptOff + 40] = 34
# Last usable LBA
$lastUsable = $totalSectors - 34
$imgBytes[$gptOff + 48] = [byte]($lastUsable -band 0xFF)
$imgBytes[$gptOff + 49] = [byte](($lastUsable -shr 8) -band 0xFF)
$imgBytes[$gptOff + 50] = [byte](($lastUsable -shr 16) -band 0xFF)
$imgBytes[$gptOff + 51] = [byte](($lastUsable -shr 24) -band 0xFF)
# Disk GUID (random)
$diskGuid = [guid]::NewGuid().ToByteArray()
[Array]::Copy($diskGuid, 0, $imgBytes, $gptOff + 56, 16)
# Partition entry start LBA = 2
$imgBytes[$gptOff + 72] = 2
# Number of partition entries = 128
$imgBytes[$gptOff + 80] = 128
# Size of partition entry = 128
$imgBytes[$gptOff + 84] = 128

# === GPT PARTITION ENTRY (LBA 2, offset 1024) ===
$peOff = 2 * $sectorSize  # 1024
# EFI System Partition GUID type: C12A7328-F81F-11D2-BA4B-00A0C93EC93B
$espTypeGuid = [byte[]](0x28, 0x73, 0x2A, 0xC1, 0x1F, 0xF8, 0xD2, 0x11, 0xBA, 0x4B, 0x00, 0xA0, 0xC9, 0x3E, 0xC9, 0x3B)
[Array]::Copy($espTypeGuid, 0, $imgBytes, $peOff, 16)
# Unique partition GUID
$partGuid = [guid]::NewGuid().ToByteArray()
[Array]::Copy($partGuid, 0, $imgBytes, $peOff + 16, 16)
# Starting LBA
$imgBytes[$peOff + 32] = [byte]($partStartLBA -band 0xFF)
$imgBytes[$peOff + 33] = [byte](($partStartLBA -shr 8) -band 0xFF)
$imgBytes[$peOff + 34] = [byte](($partStartLBA -shr 16) -band 0xFF)
$imgBytes[$peOff + 35] = [byte](($partStartLBA -shr 24) -band 0xFF)
# Ending LBA
$endLBA = $partEndLBA - 1
$imgBytes[$peOff + 40] = [byte]($endLBA -band 0xFF)
$imgBytes[$peOff + 41] = [byte](($endLBA -shr 8) -band 0xFF)
$imgBytes[$peOff + 42] = [byte](($endLBA -shr 16) -band 0xFF)
$imgBytes[$peOff + 43] = [byte](($endLBA -shr 24) -band 0xFF)
# Attributes = 0
# Partition name "EFI System" in UTF-16LE
$partName = [System.Text.Encoding]::Unicode.GetBytes('EFI System')
[Array]::Copy($partName, 0, $imgBytes, $peOff + 56, $partName.Length)

# === CRC32 for partition entries ===
function Get-CRC32([byte[]]$data) {
    # Use .NET for CRC32 to avoid PowerShell uint32 issues
    $ms = New-Object System.IO.MemoryStream(,$data)
    # Manual CRC32 using signed int arithmetic
    [long]$crc = 0xFFFFFFFF
    $table = New-Object long[] 256
    for ($i = 0; $i -lt 256; $i++) {
        [long]$c = $i
        for ($j = 0; $j -lt 8; $j++) {
            if ($c -band 1) { $c = 0xEDB88320 -bxor (($c -shr 1) -band 0x7FFFFFFF) }
            else { $c = ($c -shr 1) -band 0x7FFFFFFF }
        }
        $table[$i] = $c
    }
    foreach ($b in $data) {
        $idx = ($crc -bxor $b) -band 0xFF
        $crc = $table[$idx] -bxor (($crc -shr 8) -band 0x00FFFFFF)
    }
    $crc = $crc -bxor 0xFFFFFFFF
    return $crc -band 0xFFFFFFFF
}

# CRC32 of partition entries (128 entries * 128 bytes = 16384 bytes starting at LBA 2)
$peData = New-Object byte[] 16384
[Array]::Copy($imgBytes, 2 * $sectorSize, $peData, 0, 16384)
$peCRC = Get-CRC32 $peData
$imgBytes[$gptOff + 88] = [byte]($peCRC -band 0xFF)
$imgBytes[$gptOff + 89] = [byte](($peCRC -shr 8) -band 0xFF)
$imgBytes[$gptOff + 90] = [byte](($peCRC -shr 16) -band 0xFF)
$imgBytes[$gptOff + 91] = [byte](($peCRC -shr 24) -band 0xFF)

# CRC32 of header (zero out CRC field first, compute, write back)
$imgBytes[$gptOff + 16] = 0; $imgBytes[$gptOff + 17] = 0; $imgBytes[$gptOff + 18] = 0; $imgBytes[$gptOff + 19] = 0
$hdrData = New-Object byte[] 92
[Array]::Copy($imgBytes, $gptOff, $hdrData, 0, 92)
$hdrCRC = Get-CRC32 $hdrData
$imgBytes[$gptOff + 16] = [byte]($hdrCRC -band 0xFF)
$imgBytes[$gptOff + 17] = [byte](($hdrCRC -shr 8) -band 0xFF)
$imgBytes[$gptOff + 18] = [byte](($hdrCRC -shr 16) -band 0xFF)
$imgBytes[$gptOff + 19] = [byte](($hdrCRC -shr 24) -band 0xFF)

# === Backup GPT (at end of disk) ===
# Backup partition entries at LBA (totalSectors - 33) through (totalSectors - 2)
$backupPEStart = ($totalSectors - 33) * $sectorSize
[Array]::Copy($imgBytes, 2 * $sectorSize, $imgBytes, $backupPEStart, 16384)

# Backup GPT header at last LBA
$backupHdrOff = ($totalSectors - 1) * $sectorSize
[Array]::Copy($imgBytes, $gptOff, $imgBytes, $backupHdrOff, 92)
# Fix: My LBA = last sector, Alternate LBA = 1, Partition entry LBA = totalSectors-33
$imgBytes[$backupHdrOff + 24] = [byte]($alt -band 0xFF)
$imgBytes[$backupHdrOff + 25] = [byte](($alt -shr 8) -band 0xFF)
$imgBytes[$backupHdrOff + 26] = [byte](($alt -shr 16) -band 0xFF)
$imgBytes[$backupHdrOff + 27] = [byte](($alt -shr 24) -band 0xFF)
$imgBytes[$backupHdrOff + 28] = 0; $imgBytes[$backupHdrOff + 29] = 0; $imgBytes[$backupHdrOff + 30] = 0; $imgBytes[$backupHdrOff + 31] = 0
$imgBytes[$backupHdrOff + 32] = 1  # Alternate = primary header
$imgBytes[$backupHdrOff + 33] = 0; $imgBytes[$backupHdrOff + 34] = 0; $imgBytes[$backupHdrOff + 35] = 0
# Partition entry start for backup
$bpeLBA = $totalSectors - 33
$imgBytes[$backupHdrOff + 72] = [byte]($bpeLBA -band 0xFF)
$imgBytes[$backupHdrOff + 73] = [byte](($bpeLBA -shr 8) -band 0xFF)
$imgBytes[$backupHdrOff + 74] = [byte](($bpeLBA -shr 16) -band 0xFF)
$imgBytes[$backupHdrOff + 75] = [byte](($bpeLBA -shr 24) -band 0xFF)
# Recompute backup header CRC
$imgBytes[$backupHdrOff + 16] = 0; $imgBytes[$backupHdrOff + 17] = 0; $imgBytes[$backupHdrOff + 18] = 0; $imgBytes[$backupHdrOff + 19] = 0
$bhdrData = New-Object byte[] 92
[Array]::Copy($imgBytes, $backupHdrOff, $bhdrData, 0, 92)
$bhdrCRC = Get-CRC32 $bhdrData
$imgBytes[$backupHdrOff + 16] = [byte]($bhdrCRC -band 0xFF)
$imgBytes[$backupHdrOff + 17] = [byte](($bhdrCRC -shr 8) -band 0xFF)
$imgBytes[$backupHdrOff + 18] = [byte](($bhdrCRC -shr 16) -band 0xFF)
$imgBytes[$backupHdrOff + 19] = [byte](($bhdrCRC -shr 24) -band 0xFF)

# === FAT32 FILESYSTEM in EFI System Partition ===
$fatOff = $partStartLBA * $sectorSize
$fatSectors = $partSectors

# FAT32 BPB (BIOS Parameter Block)
$bytesPerSector = 512
$sectorsPerCluster = 8  # 4KB clusters
$reservedSectors = 32
$numFATs = 2
$totalFATSectors = $fatSectors
$fatSizeSectors = [math]::Ceiling(($totalFATSectors / $sectorsPerCluster * 4) / $bytesPerSector)
# Round up FAT size
if ($fatSizeSectors -lt 128) { $fatSizeSectors = 128 }

# Jump boot code
$imgBytes[$fatOff + 0] = 0xEB; $imgBytes[$fatOff + 1] = 0x58; $imgBytes[$fatOff + 2] = 0x90
# OEM name
[System.Text.Encoding]::ASCII.GetBytes('MSDOS5.0').CopyTo($imgBytes, $fatOff + 3)
# Bytes per sector
$imgBytes[$fatOff + 11] = [byte]($bytesPerSector -band 0xFF)
$imgBytes[$fatOff + 12] = [byte](($bytesPerSector -shr 8) -band 0xFF)
# Sectors per cluster
$imgBytes[$fatOff + 13] = $sectorsPerCluster
# Reserved sectors
$imgBytes[$fatOff + 14] = [byte]($reservedSectors -band 0xFF)
$imgBytes[$fatOff + 15] = [byte](($reservedSectors -shr 8) -band 0xFF)
# Number of FATs
$imgBytes[$fatOff + 16] = $numFATs
# Root entry count = 0 (FAT32)
$imgBytes[$fatOff + 17] = 0; $imgBytes[$fatOff + 18] = 0
# Total sectors 16 = 0 (use 32-bit field)
$imgBytes[$fatOff + 19] = 0; $imgBytes[$fatOff + 20] = 0
# Media type
$imgBytes[$fatOff + 21] = 0xF8
# FAT size 16 = 0 (FAT32)
$imgBytes[$fatOff + 22] = 0; $imgBytes[$fatOff + 23] = 0
# Sectors per track
$imgBytes[$fatOff + 24] = 63; $imgBytes[$fatOff + 25] = 0
# Number of heads
$imgBytes[$fatOff + 26] = 255; $imgBytes[$fatOff + 27] = 0
# Hidden sectors = partition start
$imgBytes[$fatOff + 28] = [byte]($partStartLBA -band 0xFF)
$imgBytes[$fatOff + 29] = [byte](($partStartLBA -shr 8) -band 0xFF)
$imgBytes[$fatOff + 30] = [byte](($partStartLBA -shr 16) -band 0xFF)
$imgBytes[$fatOff + 31] = [byte](($partStartLBA -shr 24) -band 0xFF)
# Total sectors 32
$imgBytes[$fatOff + 32] = [byte]($totalFATSectors -band 0xFF)
$imgBytes[$fatOff + 33] = [byte](($totalFATSectors -shr 8) -band 0xFF)
$imgBytes[$fatOff + 34] = [byte](($totalFATSectors -shr 16) -band 0xFF)
$imgBytes[$fatOff + 35] = [byte](($totalFATSectors -shr 24) -band 0xFF)

# --- FAT32 Extended BPB ---
# FAT size 32
$imgBytes[$fatOff + 36] = [byte]($fatSizeSectors -band 0xFF)
$imgBytes[$fatOff + 37] = [byte](($fatSizeSectors -shr 8) -band 0xFF)
$imgBytes[$fatOff + 38] = [byte](($fatSizeSectors -shr 16) -band 0xFF)
$imgBytes[$fatOff + 39] = [byte](($fatSizeSectors -shr 24) -band 0xFF)
# Ext flags = 0
$imgBytes[$fatOff + 40] = 0; $imgBytes[$fatOff + 41] = 0
# FS version = 0
$imgBytes[$fatOff + 42] = 0; $imgBytes[$fatOff + 43] = 0
# Root cluster = 2
$imgBytes[$fatOff + 44] = 2; $imgBytes[$fatOff + 45] = 0; $imgBytes[$fatOff + 46] = 0; $imgBytes[$fatOff + 47] = 0
# FS info sector = 1
$imgBytes[$fatOff + 48] = 1; $imgBytes[$fatOff + 49] = 0
# Backup boot sector = 6
$imgBytes[$fatOff + 50] = 6; $imgBytes[$fatOff + 51] = 0

# Extended boot record
$imgBytes[$fatOff + 64] = 0x80  # Drive number
$imgBytes[$fatOff + 66] = 0x29  # Extended boot signature
# Volume serial
$serial = [guid]::NewGuid().ToByteArray()
[Array]::Copy($serial, 0, $imgBytes, $fatOff + 67, 4)
# Volume label
[System.Text.Encoding]::ASCII.GetBytes('NEXUS_UEFI ').CopyTo($imgBytes, $fatOff + 71)
# FS type
[System.Text.Encoding]::ASCII.GetBytes('FAT32   ').CopyTo($imgBytes, $fatOff + 82)
# Boot sector signature
$imgBytes[$fatOff + 510] = 0x55; $imgBytes[$fatOff + 511] = 0xAA

# Backup boot sector at sector 6
[Array]::Copy($imgBytes, $fatOff, $imgBytes, $fatOff + 6 * 512, 512)

# FS Info sector (sector 1)
$fsiOff = $fatOff + 512
$imgBytes[$fsiOff + 0] = 0x52; $imgBytes[$fsiOff + 1] = 0x52; $imgBytes[$fsiOff + 2] = 0x61; $imgBytes[$fsiOff + 3] = 0x41  # RRaA
$imgBytes[$fsiOff + 484] = 0x72; $imgBytes[$fsiOff + 485] = 0x72; $imgBytes[$fsiOff + 486] = 0x41; $imgBytes[$fsiOff + 487] = 0x61  # rrAa
# Free cluster count (0xFFFFFFFF = unknown)
$imgBytes[$fsiOff + 488] = 0xFF; $imgBytes[$fsiOff + 489] = 0xFF; $imgBytes[$fsiOff + 490] = 0xFF; $imgBytes[$fsiOff + 491] = 0xFF
# Next free cluster hint
$imgBytes[$fsiOff + 492] = 0x05; $imgBytes[$fsiOff + 493] = 0x00; $imgBytes[$fsiOff + 494] = 0x00; $imgBytes[$fsiOff + 495] = 0x00
$imgBytes[$fsiOff + 510] = 0x55; $imgBytes[$fsiOff + 511] = 0xAA

# === FAT tables ===
$fat1Off = $fatOff + $reservedSectors * $sectorSize
$fat2Off = $fat1Off + $fatSizeSectors * $sectorSize

# FAT entry 0: media byte | 0x0FFFFF00
$imgBytes[$fat1Off + 0] = 0xF8; $imgBytes[$fat1Off + 1] = 0xFF; $imgBytes[$fat1Off + 2] = 0xFF; $imgBytes[$fat1Off + 3] = 0x0F
# FAT entry 1: EOC
$imgBytes[$fat1Off + 4] = 0xFF; $imgBytes[$fat1Off + 5] = 0xFF; $imgBytes[$fat1Off + 6] = 0xFF; $imgBytes[$fat1Off + 7] = 0x0F
# FAT entry 2: Root dir cluster - EOC
$imgBytes[$fat1Off + 8] = 0xFF; $imgBytes[$fat1Off + 9] = 0xFF; $imgBytes[$fat1Off + 10] = 0xFF; $imgBytes[$fat1Off + 11] = 0x0F
# FAT entry 3: EFI dir cluster - EOC
$imgBytes[$fat1Off + 12] = 0xFF; $imgBytes[$fat1Off + 13] = 0xFF; $imgBytes[$fat1Off + 14] = 0xFF; $imgBytes[$fat1Off + 15] = 0x0F
# FAT entry 4: BOOT dir cluster - EOC
$imgBytes[$fat1Off + 16] = 0xFF; $imgBytes[$fat1Off + 17] = 0xFF; $imgBytes[$fat1Off + 18] = 0xFF; $imgBytes[$fat1Off + 19] = 0x0F

# Clusters for files:
# BOOTX64.EFI: ~66KB = 17 clusters at 4KB/cluster. Start at cluster 5.
$efiClusters = [math]::Ceiling($efiSize / ($sectorsPerCluster * $sectorSize))
$kernClusters = [math]::Ceiling($kernSize / ($sectorsPerCluster * $sectorSize))

# Chain clusters for BOOTX64.EFI starting at cluster 5
for ($i = 0; $i -lt $efiClusters; $i++) {
    $cluster = 5 + $i
    $fatEntry = $fat1Off + $cluster * 4
    if ($i -eq $efiClusters - 1) {
        # Last cluster: EOC
        $imgBytes[$fatEntry] = 0xFF; $imgBytes[$fatEntry + 1] = 0xFF; $imgBytes[$fatEntry + 2] = 0xFF; $imgBytes[$fatEntry + 3] = 0x0F
    } else {
        # Next cluster
        $next = $cluster + 1
        $imgBytes[$fatEntry] = [byte]($next -band 0xFF)
        $imgBytes[$fatEntry + 1] = [byte](($next -shr 8) -band 0xFF)
        $imgBytes[$fatEntry + 2] = [byte](($next -shr 16) -band 0xFF)
        $imgBytes[$fatEntry + 3] = [byte](($next -shr 24) -band 0x0F)
    }
}

# Chain clusters for KERNEL.BIN starting after BOOTX64
$kernStart = 5 + $efiClusters
for ($i = 0; $i -lt $kernClusters; $i++) {
    $cluster = $kernStart + $i
    $fatEntry = $fat1Off + $cluster * 4
    if ($i -eq $kernClusters - 1) {
        $imgBytes[$fatEntry] = 0xFF; $imgBytes[$fatEntry + 1] = 0xFF; $imgBytes[$fatEntry + 2] = 0xFF; $imgBytes[$fatEntry + 3] = 0x0F
    } else {
        $next = $cluster + 1
        $imgBytes[$fatEntry] = [byte]($next -band 0xFF)
        $imgBytes[$fatEntry + 1] = [byte](($next -shr 8) -band 0xFF)
        $imgBytes[$fatEntry + 2] = [byte](($next -shr 16) -band 0xFF)
        $imgBytes[$fatEntry + 3] = [byte](($next -shr 24) -band 0x0F)
    }
}

# Copy FAT1 to FAT2
[Array]::Copy($imgBytes, $fat1Off, $imgBytes, $fat2Off, $fatSizeSectors * $sectorSize)

# === Data area (clusters start at cluster 2) ===
$dataOff = $fat2Off + $fatSizeSectors * $sectorSize
$clusterSize = $sectorsPerCluster * $sectorSize  # 4096

# Cluster 2: Root directory
$rootDirOff = $dataOff  # cluster 2 = first data cluster
# Volume label entry
[System.Text.Encoding]::ASCII.GetBytes('NEXUS_UEFI ').CopyTo($imgBytes, $rootDirOff)
$imgBytes[$rootDirOff + 11] = 0x08  # Volume label attribute
# "EFI" directory entry
$efiDirOff = $rootDirOff + 32
[System.Text.Encoding]::ASCII.GetBytes('EFI        ').CopyTo($imgBytes, $efiDirOff)
$imgBytes[$efiDirOff + 11] = 0x10  # Directory attribute
# Start cluster = 3
$imgBytes[$efiDirOff + 26] = 3; $imgBytes[$efiDirOff + 27] = 0
$imgBytes[$efiDirOff + 20] = 0; $imgBytes[$efiDirOff + 21] = 0

# Cluster 3: EFI directory
$efiDirDataOff = $dataOff + $clusterSize  # cluster 3
# "." entry
[System.Text.Encoding]::ASCII.GetBytes('.          ').CopyTo($imgBytes, $efiDirDataOff)
$imgBytes[$efiDirDataOff + 11] = 0x10
$imgBytes[$efiDirDataOff + 26] = 3; $imgBytes[$efiDirDataOff + 27] = 0
# ".." entry
$dotdotOff = $efiDirDataOff + 32
[System.Text.Encoding]::ASCII.GetBytes('..         ').CopyTo($imgBytes, $dotdotOff)
$imgBytes[$dotdotOff + 11] = 0x10
$imgBytes[$dotdotOff + 26] = 0; $imgBytes[$dotdotOff + 27] = 0
# "BOOT" subdirectory
$bootEntryOff = $efiDirDataOff + 64
[System.Text.Encoding]::ASCII.GetBytes('BOOT       ').CopyTo($imgBytes, $bootEntryOff)
$imgBytes[$bootEntryOff + 11] = 0x10
$imgBytes[$bootEntryOff + 26] = 4; $imgBytes[$bootEntryOff + 27] = 0

# Cluster 4: BOOT directory
$bootDirDataOff = $dataOff + 2 * $clusterSize  # cluster 4
# "." entry
[System.Text.Encoding]::ASCII.GetBytes('.          ').CopyTo($imgBytes, $bootDirDataOff)
$imgBytes[$bootDirDataOff + 11] = 0x10
$imgBytes[$bootDirDataOff + 26] = 4; $imgBytes[$bootDirDataOff + 27] = 0
# ".." entry
$dotdotOff2 = $bootDirDataOff + 32
[System.Text.Encoding]::ASCII.GetBytes('..         ').CopyTo($imgBytes, $dotdotOff2)
$imgBytes[$dotdotOff2 + 11] = 0x10
$imgBytes[$dotdotOff2 + 26] = 3; $imgBytes[$dotdotOff2 + 27] = 0

# BOOTX64.EFI entry (8.3 name: "BOOTX64 EFI")
$bootx64EntryOff = $bootDirDataOff + 64
[System.Text.Encoding]::ASCII.GetBytes('BOOTX64 EFI').CopyTo($imgBytes, $bootx64EntryOff)
$imgBytes[$bootx64EntryOff + 11] = 0x20  # Archive
# Start cluster = 5
$imgBytes[$bootx64EntryOff + 26] = 5; $imgBytes[$bootx64EntryOff + 27] = 0
$imgBytes[$bootx64EntryOff + 20] = 0; $imgBytes[$bootx64EntryOff + 21] = 0
# File size
$imgBytes[$bootx64EntryOff + 28] = [byte]($efiSize -band 0xFF)
$imgBytes[$bootx64EntryOff + 29] = [byte](($efiSize -shr 8) -band 0xFF)
$imgBytes[$bootx64EntryOff + 30] = [byte](($efiSize -shr 16) -band 0xFF)
$imgBytes[$bootx64EntryOff + 31] = [byte](($efiSize -shr 24) -band 0xFF)

# KERNEL.BIN entry (8.3 name: "KERNEL  BIN")
$kernEntryOff = $bootDirDataOff + 96
[System.Text.Encoding]::ASCII.GetBytes('KERNEL  BIN').CopyTo($imgBytes, $kernEntryOff)
$imgBytes[$kernEntryOff + 11] = 0x20  # Archive
# Start cluster
$imgBytes[$kernEntryOff + 26] = [byte]($kernStart -band 0xFF)
$imgBytes[$kernEntryOff + 27] = [byte](($kernStart -shr 8) -band 0xFF)
$imgBytes[$kernEntryOff + 20] = [byte](($kernStart -shr 16) -band 0xFF)
$imgBytes[$kernEntryOff + 21] = [byte](($kernStart -shr 24) -band 0xFF)
# File size
$imgBytes[$kernEntryOff + 28] = [byte]($kernSize -band 0xFF)
$imgBytes[$kernEntryOff + 29] = [byte](($kernSize -shr 8) -band 0xFF)
$imgBytes[$kernEntryOff + 30] = [byte](($kernSize -shr 16) -band 0xFF)
$imgBytes[$kernEntryOff + 31] = [byte](($kernSize -shr 24) -band 0xFF)

# === Write file data ===
# BOOTX64.EFI at cluster 5
$efiDataOff = $dataOff + 3 * $clusterSize  # clusters 2,3,4 used, so cluster 5 = offset 3*clusterSize
$efiData = [System.IO.File]::ReadAllBytes($BOOTX64)
[Array]::Copy($efiData, 0, $imgBytes, $efiDataOff, $efiData.Length)

# KERNEL.BIN after BOOTX64
$kernDataOff = $efiDataOff + $efiClusters * $clusterSize
$kernData = [System.IO.File]::ReadAllBytes($KERNEL)
[Array]::Copy($kernData, 0, $imgBytes, $kernDataOff, $kernData.Length)

# === Write image file ===
[System.IO.File]::WriteAllBytes($IMG, $imgBytes)
Write-Host "  OK - nexus_uefi.img ($(($imgBytes.Length / 1MB).ToString('F1'))MB)" -ForegroundColor Green
Write-Host ''
Write-Host '  Boot commands:' -ForegroundColor Yellow
Write-Host "    qemu-system-x86_64 -bios build\OVMF.fd -drive file=build\nexus_uefi.img,format=raw -m 512M -vga std" -ForegroundColor Gray
Write-Host ''
