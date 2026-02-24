$ErrorActionPreference = 'SilentlyContinue'
$QEMU = 'C:\Program Files\qemu\qemu-system-x86_64.exe'
$BUILD = Join-Path $PSScriptRoot 'build'
$SERIAL = Join-Path $BUILD 'serial.log'
$SCREEN = Join-Path $BUILD 'screen.ppm'

Remove-Item $SERIAL -Force -ErrorAction SilentlyContinue
Remove-Item $SCREEN -Force -ErrorAction SilentlyContinue

$proc = Start-Process -FilePath $QEMU -ArgumentList @(
    '-bios', "$BUILD\OVMF.fd",
    '-drive', "file=fat:rw:$BUILD\esp",
    '-drive', "format=raw,file=$BUILD\data.img,if=ide,index=1",
    '-m', '256M',
    '-vga', 'std',
    '-serial', "file:$SERIAL",
    '-display', 'none',
    '-no-reboot',
    '-monitor', 'telnet:127.0.0.1:4444,server,nowait'
) -PassThru

Start-Sleep -Seconds 3

try {
    $client = New-Object System.Net.Sockets.TcpClient('127.0.0.1', 4444)
    $stream = $client.GetStream()
    $writer = New-Object System.IO.StreamWriter($stream)
    $writer.AutoFlush = $true

    Start-Sleep -Milliseconds 500
    $writer.WriteLine('screendump build/screen.ppm')
    Start-Sleep -Seconds 2
    $writer.WriteLine('quit')
    Start-Sleep -Milliseconds 500
    $client.Close()
} catch {
    Write-Host "Monitor error: $_"
}

Start-Sleep -Seconds 2
if (!$proc.HasExited) { $proc.Kill() }

Write-Host ''
Write-Host '=== SERIAL LOG ===' -ForegroundColor Cyan
if (Test-Path $SERIAL) {
    Get-Content $SERIAL
} else {
    Write-Host '(no serial log)'
}

Write-Host ''
if (Test-Path $SCREEN) {
    $bytes = [System.IO.File]::ReadAllBytes($SCREEN)
    Write-Host "Screenshot saved: $SCREEN ($($bytes.Length) bytes)"
    # Check pixel at center (512,384) - skip PPM header
    # Read first 3 lines of PPM header
    $text = [System.Text.Encoding]::ASCII.GetString($bytes[0..100])
    Write-Host "PPM header: $($text.Substring(0,60))"
} else {
    Write-Host 'No screenshot captured'
}
