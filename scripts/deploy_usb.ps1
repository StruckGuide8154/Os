param(
    [int]$DiskNumber = 1,
    [string]$EspSource = 'C:\Users\user\Documents\new\build\esp\EFI\BOOT',
    [string]$LogPath = 'C:\Users\user\Documents\new\build\deploy_usb.log'
)
$ErrorActionPreference = 'Stop'
function Log($m) { $line = "[{0}] {1}" -f (Get-Date -Format HH:mm:ss), $m; Write-Host $line; Add-Content -Path $LogPath -Value $line }
Set-Content -Path $LogPath -Value "=== Grit USB deploy ===" -Encoding utf8

try {
    # SAFETY: only ever touch a removable USB disk.
    $d = Get-Disk -Number $DiskNumber
    Log "Target Disk $DiskNumber : $($d.FriendlyName)  $([math]::Round($d.Size/1GB,1))GB  BusType=$($d.BusType)"
    if ($d.BusType -ne 'USB') { throw "Disk $DiskNumber is not USB (BusType=$($d.BusType)). ABORT." }
    if ($d.Size -gt 256GB) { throw "Disk $DiskNumber is $([math]::Round($d.Size/1GB,1))GB (>256GB). Refusing as a safety guard. ABORT." }

    Log "Clearing disk..."
    Clear-Disk -Number $DiskNumber -RemoveData -RemoveOEM -Confirm:$false
    Get-Disk -Number $DiskNumber | Set-Disk -PartitionStyle MBR
    Log "Disk cleared, MBR initialized."

    # FAT32 in Windows is limited to ~32GB by Format-Volume. Make one 32GB
    # FAT32 boot partition (ample for the OS); rest stays unallocated.
    $diskGB = [math]::Floor($d.Size/1GB)
    $partSizeMB = [math]::Min(32000, ($diskGB * 1024) - 16)
    Log "Creating FAT32 partition (~$partSizeMB MB)..."
    $part = New-Partition -DiskNumber $DiskNumber -Size ($partSizeMB * 1MB) -AssignDriveLetter -IsActive
    $drive = "$($part.DriveLetter):"
    Log "Partition created -> $drive"

    Format-Volume -DriveLetter $part.DriveLetter -FileSystem FAT32 -NewFileSystemLabel 'GRIT' -Confirm:$false | Out-Null
    Log "Formatted $drive as FAT32 (label GRIT)."

    $dest = "$drive\EFI\BOOT"
    New-Item -Path $dest -ItemType Directory -Force | Out-Null
    foreach ($f in 'BOOTX64.EFI','KERNEL.BIN','APPS.BIN','SYSSIG.ENV','KERNEL.ENV','DATA.IMG') {
        $src = Join-Path $EspSource $f
        if (-not (Test-Path $src)) { throw "Missing build artifact: $src" }
        Copy-Item $src $dest -Force
        Log ("  copied {0} ({1:n0} bytes)" -f $f, (Get-Item $src).Length)
    }
    Log "Boot tree written to $dest"
    Log "DONE. Bootable Grit (debug) USB ready on $drive."
} catch {
    Log "ERROR: $_"
    exit 1
}
