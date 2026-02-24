# Creates a raw UEFI bootable disk image from the ESP directory
# This image can be written directly to USB or used in VirtualBox/VMware
$ErrorActionPreference = 'Stop'

$ESP_DIR  = Join-Path $PSScriptRoot 'build\esp'
$EFI_FILE = Join-Path $ESP_DIR 'EFI\BOOT\BOOTX64.EFI'
$IMG_OUT  = Join-Path $PSScriptRoot 'build\NexusOS.img'

if (-not (Test-Path $EFI_FILE)) {
    Write-Host 'ERROR: BOOTX64.EFI not found. Run build.ps1 first.' -ForegroundColor Red
    exit 1
}

Write-Host ''
Write-Host 'Creating NexusOS bootable disk image...' -ForegroundColor Cyan
Write-Host ''

$efiData = [System.IO.File]::ReadAllBytes($EFI_FILE)
$efiLen  = $efiData.Length

# Disk geometry: 64MB total image
$imgSize  = 64 * 1024 * 1024
$secSize  = 512
$totalSec = $imgSize / $secSize

# Create image buffer
$img = New-Object byte[] $imgSize

# ============================================
# Protective MBR (LBA 0)
# ============================================
# Boot signature
$img[510] = 0x55
$img[511] = 0xAA

# MBR partition entry 1 (offset 446) - GPT protective
$off = 446
$img[$off + 0]  = 0x00          # Status
$img[$off + 1]  = 0x00          # CHS first (dummy)
$img[$off + 2]  = 0x02
$img[$off + 3]  = 0x00
$img[$off + 4]  = 0xEE          # Type = GPT protective
$img[$off + 5]  = 0xFF          # CHS last (dummy)
$img[$off + 6]  = 0xFF
$img[$off + 7]  = 0xFF
# LBA start = 1
$img[$off + 8]  = 0x01
$img[$off + 9]  = 0x00
$img[$off + 10] = 0x00
$img[$off + 11] = 0x00
# LBA size
$lbaSize = $totalSec - 1
$img[$off + 12] = [byte]($lbaSize -band 0xFF)
$img[$off + 13] = [byte](($lbaSize -shr 8) -band 0xFF)
$img[$off + 14] = [byte](($lbaSize -shr 16) -band 0xFF)
$img[$off + 15] = [byte](($lbaSize -shr 24) -band 0xFF)

# ============================================
# GPT Header (LBA 1)
# ============================================
$gptOff = 512

# Helper to write values
function WriteU32($arr, $pos, $val) {
    $arr[$pos]   = [byte]($val -band 0xFF)
    $arr[$pos+1] = [byte](($val -shr 8) -band 0xFF)
    $arr[$pos+2] = [byte](($val -shr 16) -band 0xFF)
    $arr[$pos+3] = [byte](($val -shr 24) -band 0xFF)
}
function WriteU64($arr, $pos, $val) {
    for ($i = 0; $i -lt 8; $i++) {
        $arr[$pos + $i] = [byte](($val -shr ($i * 8)) -band 0xFF)
    }
}
function WriteGuid($arr, $pos, [byte[]]$guidBytes) {
    [Array]::Copy($guidBytes, 0, $arr, $pos, 16)
}

# Signature "EFI PART"
$sig = [System.Text.Encoding]::ASCII.GetBytes('EFI PART')
[Array]::Copy($sig, 0, $img, $gptOff, 8)

# Revision 1.0
WriteU32 $img ($gptOff + 8)  0x00010000
# Header size
WriteU32 $img ($gptOff + 12) 92
# CRC32 of header (fill later)
WriteU32 $img ($gptOff + 16) 0
# Reserved
WriteU32 $img ($gptOff + 20) 0
# My LBA
WriteU64 $img ($gptOff + 24) 1
# Alternate LBA (last LBA)
$lastLBA = $totalSec - 1
WriteU64 $img ($gptOff + 32) $lastLBA
# First usable LBA (after GPT entries = LBA 34)
WriteU64 $img ($gptOff + 40) 34
# Last usable LBA
WriteU64 $img ($gptOff + 48) ($totalSec - 34)
# Disk GUID (random)
$diskGuid = [guid]::NewGuid().ToByteArray()
WriteGuid $img ($gptOff + 56) $diskGuid
# Partition entries start LBA
WriteU64 $img ($gptOff + 72) 2
# Number of partition entries
WriteU32 $img ($gptOff + 80) 128
# Size of partition entry
WriteU32 $img ($gptOff + 84) 128
# CRC32 of partition entries (fill later)
WriteU32 $img ($gptOff + 88) 0

# ============================================
# GPT Partition Entry (LBA 2-33)
# ============================================
$peOff = 1024   # LBA 2

# EFI System Partition GUID type: C12A7328-F81F-11D2-BA4B-00A0C93EC93B
$espTypeGuid = @(0x28, 0x73, 0x2A, 0xC1, 0x1F, 0xF8, 0xD2, 0x11,
                 0xBA, 0x4B, 0x00, 0xA0, 0xC9, 0x3E, 0xC9, 0x3B)
WriteGuid $img $peOff ([byte[]]$espTypeGuid)

# Unique partition GUID
$partGuid = [guid]::NewGuid().ToByteArray()
WriteGuid $img ($peOff + 16) $partGuid

# First LBA (start of FAT32 partition)
$partStartLBA = 2048
WriteU64 $img ($peOff + 32) $partStartLBA
# Last LBA
$partEndLBA = $totalSec - 34
WriteU64 $img ($peOff + 40) $partEndLBA
# Attributes
WriteU64 $img ($peOff + 48) 0
# Name: "EFI System" in UTF-16LE
$pname = 'EFI System'
for ($i = 0; $i -lt $pname.Length; $i++) {
    $img[$peOff + 56 + $i*2] = [byte][char]$pname[$i]
    $img[$peOff + 57 + $i*2] = 0
}

# ============================================
# FAT32 Filesystem at partition start
# ============================================
$fatOff = $partStartLBA * $secSize
$partSectors = $partEndLBA - $partStartLBA + 1

# BPB (BIOS Parameter Block)
$img[$fatOff + 0] = 0xEB   # Jump
$img[$fatOff + 1] = 0x58
$img[$fatOff + 2] = 0x90
# OEM name
$oem = [System.Text.Encoding]::ASCII.GetBytes('NEXUSOS ')
[Array]::Copy($oem, 0, $img, $fatOff + 3, 8)

$bytesPerSec  = 512
$secPerClus   = 8       # 4KB clusters
$reservedSec  = 32
$numFATs      = 2
$fatSectors   = 128     # big enough for our small partition

# Bytes per sector
$img[$fatOff + 11] = [byte]($bytesPerSec -band 0xFF)
$img[$fatOff + 12] = [byte](($bytesPerSec -shr 8) -band 0xFF)
# Sectors per cluster
$img[$fatOff + 13] = [byte]$secPerClus
# Reserved sectors
$img[$fatOff + 14] = [byte]($reservedSec -band 0xFF)
$img[$fatOff + 15] = [byte](($reservedSec -shr 8) -band 0xFF)
# Number of FATs
$img[$fatOff + 16] = [byte]$numFATs
# Root entry count (0 for FAT32)
$img[$fatOff + 17] = 0
$img[$fatOff + 18] = 0
# Total sectors 16 (0 for FAT32)
$img[$fatOff + 19] = 0
$img[$fatOff + 20] = 0
# Media type
$img[$fatOff + 21] = 0xF8
# FAT size 16 (0 for FAT32)
$img[$fatOff + 22] = 0
$img[$fatOff + 23] = 0
# Sectors per track
$img[$fatOff + 24] = 0x3F
$img[$fatOff + 25] = 0
# Number of heads
$img[$fatOff + 26] = 0xFF
$img[$fatOff + 27] = 0
# Hidden sectors
WriteU32 $img ($fatOff + 28) $partStartLBA
# Total sectors 32
WriteU32 $img ($fatOff + 32) $partSectors
# FAT32: sectors per FAT
WriteU32 $img ($fatOff + 36) $fatSectors
# Flags
$img[$fatOff + 40] = 0
$img[$fatOff + 41] = 0
# Version
$img[$fatOff + 42] = 0
$img[$fatOff + 43] = 0
# Root cluster
WriteU32 $img ($fatOff + 44) 2
# FSInfo sector
$img[$fatOff + 48] = 1
$img[$fatOff + 49] = 0
# Backup boot sector
$img[$fatOff + 50] = 6
$img[$fatOff + 51] = 0
# Reserved
# Drive number
$img[$fatOff + 64] = 0x80
# Boot sig
$img[$fatOff + 66] = 0x29
# Volume serial
WriteU32 $img ($fatOff + 67) 0xDEADBEEF
# Volume label
$vlabel = [System.Text.Encoding]::ASCII.GetBytes('NEXUSOS    ')
[Array]::Copy($vlabel, 0, $img, $fatOff + 71, 11)
# FS type
$fstype = [System.Text.Encoding]::ASCII.GetBytes('FAT32   ')
[Array]::Copy($fstype, 0, $img, $fatOff + 82, 8)
# Boot signature
$img[$fatOff + 510] = 0x55
$img[$fatOff + 511] = 0xAA

# FSInfo sector (sector 1 of partition)
$fsiOff = $fatOff + 512
WriteU32 $img $fsiOff 0x41615252         # Lead sig
WriteU32 $img ($fsiOff + 484) 0x61417272 # Struct sig
WriteU32 $img ($fsiOff + 488) 0xFFFFFFFF # Free count unknown
WriteU32 $img ($fsiOff + 492) 0xFFFFFFFF # Next free unknown
$img[$fsiOff + 510] = 0x55
$img[$fsiOff + 511] = 0xAA

# ============================================
# FAT table
# ============================================
$fat1Off = $fatOff + ($reservedSec * $secSize)

# FAT[0] = media type marker
WriteU32 $img $fat1Off 0x0FFFFFF8
# FAT[1] = end of chain marker
WriteU32 $img ($fat1Off + 4) 0x0FFFFFFF
# FAT[2] = root dir cluster (end of chain - single cluster)
WriteU32 $img ($fat1Off + 8) 0x0FFFFFFF
# FAT[3] = EFI dir
WriteU32 $img ($fat1Off + 12) 0x0FFFFFFF
# FAT[4] = BOOT dir
WriteU32 $img ($fat1Off + 16) 0x0FFFFFFF
# FAT[5] = BOOTX64.EFI data (may chain)
# Calculate how many clusters the EFI file needs
$clusterSize = $bytesPerSec * $secPerClus  # 4096
$efiClusters = [math]::Ceiling($efiLen / $clusterSize)

for ($i = 0; $i -lt $efiClusters; $i++) {
    $clusterNum = 5 + $i
    if ($i -eq ($efiClusters - 1)) {
        WriteU32 $img ($fat1Off + $clusterNum * 4) 0x0FFFFFFF  # end
    } else {
        WriteU32 $img ($fat1Off + $clusterNum * 4) ($clusterNum + 1)  # next
    }
}

# Copy FAT1 to FAT2
$fat2Off = $fat1Off + ($fatSectors * $secSize)
[Array]::Copy($img, $fat1Off, $img, $fat2Off, $fatSectors * $secSize)

# ============================================
# Data region (cluster 2 = root dir)
# ============================================
$dataOff = $fatOff + (($reservedSec + $numFATs * $fatSectors) * $secSize)

# Root directory (cluster 2) - contains "EFI" directory entry
$rootOff = $dataOff  # cluster 2
# Volume label entry
$vlbl = [System.Text.Encoding]::ASCII.GetBytes('NEXUSOS    ')
[Array]::Copy($vlbl, 0, $img, $rootOff, 11)
$img[$rootOff + 11] = 0x08  # Attribute = Volume Label

# EFI directory entry (8.3 format)
$efiDirOff = $rootOff + 32
$ename = [System.Text.Encoding]::ASCII.GetBytes('EFI        ')
[Array]::Copy($ename, 0, $img, $efiDirOff, 11)
$img[$efiDirOff + 11] = 0x10  # Attribute = Directory
# First cluster high
$img[$efiDirOff + 20] = 0
$img[$efiDirOff + 21] = 0
# First cluster low = 3
$img[$efiDirOff + 26] = 3
$img[$efiDirOff + 27] = 0

# EFI directory (cluster 3) - contains "BOOT" directory entry
$efiClsOff = $dataOff + (3 - 2) * $clusterSize
# . entry
$dot = [System.Text.Encoding]::ASCII.GetBytes('.          ')
[Array]::Copy($dot, 0, $img, $efiClsOff, 11)
$img[$efiClsOff + 11] = 0x10
$img[$efiClsOff + 26] = 3

# .. entry
$dotdot = [System.Text.Encoding]::ASCII.GetBytes('..         ')
[Array]::Copy($dotdot, 0, $img, $efiClsOff + 32, 11)
$img[$efiClsOff + 32 + 11] = 0x10
$img[$efiClsOff + 32 + 26] = 0  # parent = root

# BOOT entry
$bootDirOff = $efiClsOff + 64
$bname = [System.Text.Encoding]::ASCII.GetBytes('BOOT       ')
[Array]::Copy($bname, 0, $img, $bootDirOff, 11)
$img[$bootDirOff + 11] = 0x10
$img[$bootDirOff + 26] = 4  # cluster 4

# BOOT directory (cluster 4)
$bootClsOff = $dataOff + (4 - 2) * $clusterSize
# . entry
[Array]::Copy($dot, 0, $img, $bootClsOff, 11)
$img[$bootClsOff + 11] = 0x10
$img[$bootClsOff + 26] = 4

# .. entry
[Array]::Copy($dotdot, 0, $img, $bootClsOff + 32, 11)
$img[$bootClsOff + 32 + 11] = 0x10
$img[$bootClsOff + 32 + 26] = 3  # parent = EFI dir

# BOOTX64.EFI file entry
$fileOff = $bootClsOff + 64
$fname = [System.Text.Encoding]::ASCII.GetBytes('BOOTX64 EFI')
[Array]::Copy($fname, 0, $img, $fileOff, 11)
$img[$fileOff + 11] = 0x20  # Attribute = Archive
# First cluster = 5
$img[$fileOff + 26] = 5
$img[$fileOff + 27] = 0
# File size
WriteU32 $img ($fileOff + 28) $efiLen

# Write EFI file data starting at cluster 5
$efiDataOff = $dataOff + (5 - 2) * $clusterSize
[Array]::Copy($efiData, 0, $img, $efiDataOff, $efiLen)

# ============================================
# Compute CRC32 for GPT
# ============================================
# Simple CRC32 implementation
function CRC32([byte[]]$data, $offset, $length) {
    [long]$crc = 0xFFFFFFFF
    for ($i = 0; $i -lt $length; $i++) {
        $crc = $crc -bxor $data[$offset + $i]
        for ($j = 0; $j -lt 8; $j++) {
            if ($crc -band 1) {
                $crc = (($crc -shr 1) -band 0x7FFFFFFF) -bxor 0xEDB88320
            } else {
                $crc = ($crc -shr 1) -band 0x7FFFFFFF
            }
        }
    }
    $crc = $crc -bxor 0xFFFFFFFF
    return [int]($crc -band 0xFFFFFFFF)
}

# CRC32 of partition entries (128 entries x 128 bytes = 16384 bytes at LBA 2)
$peCRC = CRC32 $img 1024 16384
WriteU32 $img ($gptOff + 88) $peCRC

# CRC32 of GPT header (zero the CRC field first, compute, then write)
WriteU32 $img ($gptOff + 16) 0
$hdrCRC = CRC32 $img $gptOff 92
WriteU32 $img ($gptOff + 16) $hdrCRC

# ============================================
# Write the image
# ============================================
[System.IO.File]::WriteAllBytes($IMG_OUT, $img)

$sz = (Get-Item $IMG_OUT).Length / 1MB
Write-Host "NexusOS.img created: $sz MB" -ForegroundColor Green
Write-Host ''
Write-Host 'Usage:' -ForegroundColor Yellow
Write-Host '  QEMU:       qemu-system-x86_64 -bios OVMF.fd -drive file=NexusOS.img,format=raw -m 256M' -ForegroundColor Gray
Write-Host '  VirtualBox: Create VM -> Use existing disk -> Select NexusOS.img (raw)' -ForegroundColor Gray
Write-Host '  USB Flash:  Use Rufus or dd to write NexusOS.img to USB drive' -ForegroundColor Gray
Write-Host ''
