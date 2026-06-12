param(
    [switch]$Release,
    [switch]$Trace,
    [ValidateSet('Default', 'Cache32Max')]
    [string]$PerfProfile = 'Default'
)

$ErrorActionPreference = 'Stop'
$Root = Resolve-Path (Join-Path $PSScriptRoot '..\..')

$NASM = 'C:\Tools\nasm-2.16.03\nasm.exe'
$SRC_DIR = Join-Path $Root 'src'
$BUILD_DIR = Join-Path $Root 'build'
$INCLUDE_DIR = Join-Path $Root 'src\include'
$USER_LIB_DIR = Join-Path $Root 'src\user\lib'
$ConstantsPath = Join-Path $INCLUDE_DIR 'constants.inc'
$KernelDefines = @()
if (-not $Release) {
    $KernelDefines += '-dENABLE_DEBUG_SERIAL'
    $KernelDefines += '-dENABLE_USER_DEBUG_SYSCALL'
}
else {
    $KernelDefines += '-dRELEASE_BUILD'
}
if ($PerfProfile -eq 'Cache32Max') {
    $KernelDefines += '-dGRIT_CACHE32_MAX'
    $KernelDefines += '-dGRIT_SMP'
    $KernelDefines += '-dGRIT_CACHE32_AP_STARTUP'
    $KernelDefines += '-dGRIT_ENABLE_RING3_AP'
}
if ($Trace) {
    $KernelDefines += '-dENABLE_TRACE'
    $KernelDefines += '-dENABLE_SIG_SECTION'
}

# Ensure build dir exists
if (-not (Test-Path $BUILD_DIR)) {
    New-Item -Path $BUILD_DIR -ItemType Directory | Out-Null
}

Write-Host "Grit (BIOS) Build System" -ForegroundColor Cyan
Write-Host "===========================" -ForegroundColor Cyan
Write-Host ("Mode:   " + ($(if ($Release) { 'release' } else { 'debug' })))
Write-Host "Perf:   $PerfProfile"
Write-Host ("Trace:  " + ($(if ($Trace) { 'on' } else { 'off' })))

$NxhBuildArgs = @()
if ($Release) { $NxhBuildArgs += '-Release' }
& powershell -NoProfile -File (Join-Path $Root 'scripts\build\build_ghl.ps1') @NxhBuildArgs
if ($LASTEXITCODE -ne 0) { Write-Host '  FAILED GritHL compile' -ForegroundColor Red; exit 1 }
$CoverageTool = Join-Path $Root 'tools\check_coverage.py'
if (Test-Path $CoverageTool) {
    & python $CoverageTool
    if ($LASTEXITCODE -ne 0) { Write-Host '  FAILED signature coverage' -ForegroundColor Red; exit 1 }
}
Write-Host "Source: $SRC_DIR"
Write-Host "Build:  $BUILD_DIR"

function Get-AsmEqu {
    param(
        [string]$Path,
        [string]$Name
    )
    $line = Select-String -Path $Path -Pattern "^\s*$Name\s+equ\s+(.+?)(?:\s*;.*)?$" | Select-Object -First 1
    if (-not $line) { throw "Missing $Name in $Path" }
    $expr = $line.Matches[0].Groups[1].Value.Trim()
    if ($expr -match '^0x[0-9A-Fa-f]+$') { return [Convert]::ToInt64($expr, 16) }
    if ($expr -match '^\d+$') { return [int64]$expr }
    throw "Unsupported $Name expression in ${Path}: $expr"
}

$KernelStartSector = Get-AsmEqu $ConstantsPath 'KERNEL_START_SECTOR'
$KernelSectors = Get-AsmEqu $ConstantsPath 'KERNEL_SECTORS'

# 1. MBR (Stage 1)
Write-Host "[1/3] Assembling MBR..." -ForegroundColor Yellow
# Add src\boot to include path so nasm finds files in same dir if needed
& $NASM -f bin -o "$BUILD_DIR\mbr.bin" -I "$INCLUDE_DIR\" -I "$SRC_DIR\boot\" "$SRC_DIR\boot\mbr.asm"
if ($LASTEXITCODE -ne 0) { exit 1 }

# 2. Stage 2 Bootloader
Write-Host "[2/3] Assembling Stage 2..." -ForegroundColor Yellow
& $NASM -f bin -o "$BUILD_DIR\stage2.bin" -I "$INCLUDE_DIR\" -I "$SRC_DIR\boot\" "$SRC_DIR\boot\stage2.asm"
if ($LASTEXITCODE -ne 0) { exit 1 }

# 3. Kernel (Monolithic)
Write-Host "[3/3] Assembling Kernel..." -ForegroundColor Yellow
& $NASM @KernelDefines -w-pp-macro-redef-multi -f bin -o "$BUILD_DIR\kernel.bin" -I "$INCLUDE_DIR\" -I "$USER_LIB_DIR\" -I "$SRC_DIR\boot\" -I "$BUILD_DIR\" "$SRC_DIR\kernel\kernel_build.asm"
if ($LASTEXITCODE -ne 0) { exit 1 }

# 4. Create Disk Image (Concatenate headers + kernel)
Write-Host "[4/4] Creating Disk Image (Grit.img)..." -ForegroundColor Yellow
$mbrPath = "$BUILD_DIR\mbr.bin"
$stage2Path = "$BUILD_DIR\stage2.bin"
$kernelPath = "$BUILD_DIR\kernel.bin"
$imgPath = "$BUILD_DIR\Grit.img"

# Combine files: MBR + Stage2 + Kernel using byte array concatenation in memory for safety/control
try {
    $mbrBytes = [System.IO.File]::ReadAllBytes($mbrPath)
    $stage2Bytes = [System.IO.File]::ReadAllBytes($stage2Path)
    $kernelBytes = [System.IO.File]::ReadAllBytes($kernelPath)
    
    $kernelOffset = [int]($KernelStartSector * 512)
    $kernelMaxBytes = [int]($KernelSectors * 512)
    if ($kernelBytes.Length -gt $kernelMaxBytes) {
        throw "Kernel is $($kernelBytes.Length) bytes but BIOS loader reserves only $kernelMaxBytes bytes ($KernelSectors sectors)."
    }

    $reservedKernelEnd = $kernelOffset + $kernelMaxBytes
    $totalLen = $reservedKernelEnd
    
    # Target size 10MB
    $targetSize = 10 * 1024 * 1024
    if ($totalLen -gt $targetSize) {
        $targetSize = $totalLen
    }
    
    $imgBytes = New-Object byte[] $targetSize
    
    # Copy MBR (0)
    [Array]::Copy($mbrBytes, 0, $imgBytes, 0, $mbrBytes.Length)
    
    # Copy Stage2 (512)
    [Array]::Copy($stage2Bytes, 0, $imgBytes, $mbrBytes.Length, $stage2Bytes.Length)
    
    # Copy Kernel at the sector Stage 2 loads from. The reserved kernel area is
    # fixed-size so the FAT partition can never overlap a large kernel.
    [Array]::Copy($kernelBytes, 0, $imgBytes, $kernelOffset, $kernelBytes.Length)
    
    # 5. Format FAT16 partition after the reserved BIOS kernel area.
    Write-Host "[5/5] Formatting FAT16 filesystem..." -ForegroundColor Yellow
    $fatPartStart = $reservedKernelEnd
    $fatPartSectors = [int](($targetSize - $fatPartStart) / 512)

    # FAT16 BPB parameters
    $bytesPerSect = 512
    $sectPerClus = 4         # 2KB clusters
    $reservedSects = 1       # boot sector
    $numFats = 2
    $rootEntries = 512       # 512 dir entries = 32 sectors
    $rootSectors = ($rootEntries * 32) / $bytesPerSect  # 32
    $fatEntries = [int](($fatPartSectors - $reservedSects - $rootSectors) / $sectPerClus)
    if ($fatEntries -gt 65520) { $fatEntries = 65520 }
    $fatSizeSects = [int][Math]::Ceiling(($fatEntries * 2) / $bytesPerSect)  # 2 bytes per FAT16 entry
    $dataSectors = $fatPartSectors - $reservedSects - ($numFats * $fatSizeSects) - $rootSectors
    $totalClusters = [int]($dataSectors / $sectPerClus)

    # Write BPB (boot sector of FAT16 partition)
    $bpbOff = $fatPartStart
    # Jump instruction
    $imgBytes[$bpbOff + 0] = 0xEB
    $imgBytes[$bpbOff + 1] = 0x3C
    $imgBytes[$bpbOff + 2] = 0x90
    # OEM Name
    $oem = [System.Text.Encoding]::ASCII.GetBytes("GRIT ")
    [Array]::Copy($oem, 0, $imgBytes, $bpbOff + 3, 8)
    # Bytes per sector (11-12)
    $imgBytes[$bpbOff + 11] = [byte]($bytesPerSect -band 0xFF)
    $imgBytes[$bpbOff + 12] = [byte](($bytesPerSect -shr 8) -band 0xFF)
    # Sectors per cluster (13)
    $imgBytes[$bpbOff + 13] = [byte]$sectPerClus
    # Reserved sectors (14-15)
    $imgBytes[$bpbOff + 14] = [byte]($reservedSects -band 0xFF)
    $imgBytes[$bpbOff + 15] = [byte](($reservedSects -shr 8) -band 0xFF)
    # Number of FATs (16)
    $imgBytes[$bpbOff + 16] = [byte]$numFats
    # Root entries (17-18)
    $imgBytes[$bpbOff + 17] = [byte]($rootEntries -band 0xFF)
    $imgBytes[$bpbOff + 18] = [byte](($rootEntries -shr 8) -band 0xFF)
    # Total sectors 16 (19-20)
    if ($fatPartSectors -le 65535) {
        $imgBytes[$bpbOff + 19] = [byte]($fatPartSectors -band 0xFF)
        $imgBytes[$bpbOff + 20] = [byte](($fatPartSectors -shr 8) -band 0xFF)
    }
    # Media type (21)
    $imgBytes[$bpbOff + 21] = 0xF8
    # FAT size in sectors (22-23)
    $imgBytes[$bpbOff + 22] = [byte]($fatSizeSects -band 0xFF)
    $imgBytes[$bpbOff + 23] = [byte](($fatSizeSects -shr 8) -band 0xFF)
    # Sectors per track (24-25) - dummy
    $imgBytes[$bpbOff + 24] = 63
    $imgBytes[$bpbOff + 25] = 0
    # Number of heads (26-27) - dummy
    $imgBytes[$bpbOff + 26] = 16
    $imgBytes[$bpbOff + 27] = 0
    # Boot signature (510-511)
    $imgBytes[$bpbOff + 510] = 0x55
    $imgBytes[$bpbOff + 511] = 0xAA

    # Write FAT tables (FAT1 and FAT2)
    $fat1Off = $fatPartStart + ($reservedSects * $bytesPerSect)
    # First two entries: media type marker
    $imgBytes[$fat1Off + 0] = 0xF8
    $imgBytes[$fat1Off + 1] = 0xFF
    $imgBytes[$fat1Off + 2] = 0xFF
    $imgBytes[$fat1Off + 3] = 0xFF

    # Copy FAT1 to FAT2
    $fat2Off = $fat1Off + ($fatSizeSects * $bytesPerSect)
    [Array]::Copy($imgBytes, $fat1Off, $imgBytes, $fat2Off, $fatSizeSects * $bytesPerSect)

    # Root directory starts after FAT2
    $rootDirOff = $fat2Off + ($fatSizeSects * $bytesPerSect)
    # Data region starts after root dir
    $dataOff = $rootDirOff + ($rootSectors * $bytesPerSect)

    # Helper: write a FAT16 directory entry
    function Write-DirEntry($offset, $name, $ext, $attr, $cluster, $size) {
        # Name (8 bytes, space padded)
        $nameBytes = [System.Text.Encoding]::ASCII.GetBytes($name.PadRight(8))
        [Array]::Copy($nameBytes, 0, $imgBytes, $offset, 8)
        # Extension (3 bytes, space padded)
        $extBytes = [System.Text.Encoding]::ASCII.GetBytes($ext.PadRight(3))
        [Array]::Copy($extBytes, 0, $imgBytes, $offset + 8, 3)
        # Attributes
        $imgBytes[$offset + 11] = [byte]$attr
        # First cluster low (26-27)
        $imgBytes[$offset + 26] = [byte]($cluster -band 0xFF)
        $imgBytes[$offset + 27] = [byte](($cluster -shr 8) -band 0xFF)
        # File size (28-31)
        $imgBytes[$offset + 28] = [byte]($size -band 0xFF)
        $imgBytes[$offset + 29] = [byte](($size -shr 8) -band 0xFF)
        $imgBytes[$offset + 30] = [byte](($size -shr 16) -band 0xFF)
        $imgBytes[$offset + 31] = [byte](($size -shr 24) -band 0xFF)
    }

    # Helper: write file data to cluster and update FAT
    $nextFreeCluster = 2
    function Write-FileData($data) {
        $bytesWritten = 0
        $firstCluster = $script:nextFreeCluster
        $prevCluster = -1
        $clusterSize = $sectPerClus * $bytesPerSect  # 2048

        while ($bytesWritten -lt $data.Length) {
            $cluster = $script:nextFreeCluster
            $script:nextFreeCluster++

            # Link previous cluster
            if ($prevCluster -ge 2) {
                $fatOff = $fat1Off + ($prevCluster * 2)
                $imgBytes[$fatOff] = [byte]($cluster -band 0xFF)
                $imgBytes[$fatOff + 1] = [byte](($cluster -shr 8) -band 0xFF)
            }

            # Write data to this cluster
            $clusterOff = $dataOff + (($cluster - 2) * $clusterSize)
            $remaining = $data.Length - $bytesWritten
            $writeLen = [Math]::Min($remaining, $clusterSize)
            [Array]::Copy($data, $bytesWritten, $imgBytes, $clusterOff, $writeLen)
            $bytesWritten += $writeLen
            $prevCluster = $cluster
        }

        # Mark end of chain
        if ($prevCluster -ge 2) {
            $fatOff = $fat1Off + ($prevCluster * 2)
            $imgBytes[$fatOff] = 0xFF
            $imgBytes[$fatOff + 1] = 0xFF
        }

        return $firstCluster
    }

    # Create sample files
    $entryIdx = 0

    # Volume label
    Write-DirEntry ($rootDirOff + $entryIdx * 32) "GRIT" "   " 0x08 0 0
    $entryIdx++

    # DOCS directory
    $docsCluster = $script:nextFreeCluster
    $script:nextFreeCluster++
    Write-DirEntry ($rootDirOff + $entryIdx * 32) "DOCS" "   " 0x10 $docsCluster 0
    $entryIdx++

    # Prepare DOCS directory content (cluster)
    $docsDirOff = $dataOff + (($docsCluster - 2) * $clusterSize)
    # 1. "." entry
    Write-DirEntry $docsDirOff "." "   " 0x10 $docsCluster 0
    # 2. ".." entry
    Write-DirEntry ($docsDirOff + 32) ".." "   " 0x10 0 0
    
    # Add a file inside DOCS
    $secretText = "This is a secret file inside the DOCS directory!`r`n"
    $secretData = [System.Text.Encoding]::ASCII.GetBytes($secretText)
    $secretCluster = Write-FileData $secretData
    # Write entry into DOCS directory (3rd slot)
    Write-DirEntry ($docsDirOff + 64) "SECRET" "TXT" 0x20 $secretCluster $secretData.Length

    # README.TXT (back in root)
    $readmeText = "Welcome to Grit v3.0!`r`nThis is a 64-bit operating system written entirely in x86-64 assembly.`r`n`r`nFeatures:`r`n- Graphical desktop environment`r`n- Window manager with drag support`r`n- File explorer with real FAT16 filesystem`r`n- Built-in text editor (Notepad)`r`n- Terminal with basic commands`r`n`r`nEnjoy exploring!`r`n"
    $readmeData = [System.Text.Encoding]::ASCII.GetBytes($readmeText)
    $readmeCluster = Write-FileData $readmeData
    Write-DirEntry ($rootDirOff + $entryIdx * 32) "README" "TXT" 0x20 $readmeCluster $readmeData.Length
    $entryIdx++

    # HELLO.TXT
    $helloText = "Hello from Grit!`r`nThis file is stored on a real FAT16 filesystem.`r`nYou can edit this in Notepad and save it back.`r`n"
    $helloData = [System.Text.Encoding]::ASCII.GetBytes($helloText)
    $helloCluster = Write-FileData $helloData
    Write-DirEntry ($rootDirOff + $entryIdx * 32) "HELLO" "TXT" 0x20 $helloCluster $helloData.Length
    $entryIdx++

    # NOTES.TXT
    $notesText = "My Notes`r`n========`r`n`r`nTODO:`r`n- Learn assembly programming`r`n- Build an OS from scratch`r`n- Add more features`r`n"
    $notesData = [System.Text.Encoding]::ASCII.GetBytes($notesText)
    $notesCluster = Write-FileData $notesData
    Write-DirEntry ($rootDirOff + $entryIdx * 32) "NOTES" "TXT" 0x20 $notesCluster $notesData.Length
    $entryIdx++

    # SYSTEM.TXT (system info)
    $sysText = "Grit System Information`r`n==========================`r`nKernel: Grit v3.0`r`nArch: x86-64`r`nDisplay: 1024x768 32bpp`r`nFS: FAT16`r`n"
    $sysData = [System.Text.Encoding]::ASCII.GetBytes($sysText)
    $sysCluster = Write-FileData $sysData
    Write-DirEntry ($rootDirOff + $entryIdx * 32) "SYSTEM" "TXT" 0x20 $sysCluster $sysData.Length
    $entryIdx++

    # LOGO.BMP
    $bmpWidth = 16
    $bmpHeight = 16
    $bmpRowSize = $bmpWidth * 3
    if ($bmpRowSize % 4 -ne 0) { $bmpRowSize += 4 - ($bmpRowSize % 4) }
    $bmpDataSize = $bmpRowSize * $bmpHeight
    $bmpFileSize = 54 + $bmpDataSize
    $bmpData = New-Object byte[] $bmpFileSize
    $bmpData[0] = 0x42; $bmpData[1] = 0x4D
    $bmpData[2] = [byte]($bmpFileSize -band 0xFF)
    $bmpData[3] = [byte](($bmpFileSize -shr 8) -band 0xFF)
    $bmpData[10] = 54
    $bmpData[14] = 40
    $bmpData[18] = [byte]$bmpWidth
    $bmpData[22] = [byte]$bmpHeight
    $bmpData[26] = 1
    $bmpData[28] = 24
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

    # Copy FAT1 to FAT2 again (after writing all files)
    [Array]::Copy($imgBytes, $fat1Off, $imgBytes, $fat2Off, $fatSizeSects * $bytesPerSect)

    Write-Host "  FAT16: $totalClusters clusters, $fatSizeSects FAT sectors, $($entryIdx - 1) files, 1 directory" -ForegroundColor Gray

    [System.IO.File]::WriteAllBytes($imgPath, $imgBytes)

    Write-Host "Build Successful!" -ForegroundColor Green
    Write-Host "Image Path: $imgPath" -ForegroundColor White
    Write-Host "Image Size: $($imgBytes.Length) bytes"
} catch {
    Write-Host "Error creating image: $_" -ForegroundColor Red
    exit 1
}
