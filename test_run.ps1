$ErrorActionPreference = 'Continue'
$QEMU = 'C:\Program Files\qemu\qemu-system-x86_64.exe'
$IMG = Join-Path $PSScriptRoot 'build\NexusOS.img'
$SERIAL = Join-Path $PSScriptRoot 'build\serial.log'
$PPM = Join-Path $PSScriptRoot 'build\test_sse.ppm'

# Clean old logs
if (Test-Path $SERIAL) { Remove-Item $SERIAL }

# Start QEMU in background
$proc = Start-Process -FilePath $QEMU -ArgumentList @(
    "-drive", "file=$IMG,format=raw",
    "-m", "128M",
    "-vga", "std",
    "-serial", "file:$SERIAL",
    "-monitor", "telnet:127.0.0.1:4455,server,nowait",
    "-display", "none"
) -PassThru -NoNewWindow

Start-Sleep -Seconds 5

try {
    $client = New-Object System.Net.Sockets.TcpClient('127.0.0.1', 4455)
    $stream = $client.GetStream()
    $writer = New-Object System.IO.StreamWriter($stream)
    $reader = New-Object System.IO.StreamReader($stream)
    Start-Sleep -Milliseconds 500

    # Take screenshot
    $writer.WriteLine("screendump $PPM")
    $writer.Flush()
    Start-Sleep -Seconds 2

    # Quit
    $writer.WriteLine("quit")
    $writer.Flush()
    Start-Sleep -Milliseconds 500
    $client.Close()
} catch {
    Write-Host "Monitor error: $_"
}

Start-Sleep -Seconds 1

# Print serial log
if (Test-Path $SERIAL) {
    Write-Host "=== Serial Log ===" -ForegroundColor Cyan
    Get-Content $SERIAL
} else {
    Write-Host "No serial log found"
}

# Check screenshot
if (Test-Path $PPM) {
    $sz = (Get-Item $PPM).Length
    Write-Host "`n=== Screenshot: $sz bytes ===" -ForegroundColor Cyan
    # Read first line and check for valid PPM
    $header = Get-Content $PPM -TotalCount 3
    Write-Host "PPM Header: $($header -join ' | ')"
} else {
    Write-Host "No screenshot captured"
}

# Kill QEMU if still running
if (!$proc.HasExited) { $proc.Kill() }
