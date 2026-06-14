# Boot the built UEFI image headless, wait for the GUI, and capture a QEMU
# monitor screendump (PPM) to verify the desktop actually renders.
param([int]$WaitMs = 9000, [string]$Out = 'build\shot.ppm')
$ErrorActionPreference = 'Continue'
$Root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$OutPath = Join-Path $Root $Out

function Stop-Qemu {
    try {
        $c = [System.Net.Sockets.TcpClient]::new(); $c.Connect('127.0.0.1', 4444)
        $s = $c.GetStream(); $b = [System.Text.Encoding]::ASCII.GetBytes("quit`r`n")
        $s.Write($b, 0, $b.Length); $s.Flush(); $c.Close(); Start-Sleep -Milliseconds 400
    } catch {}
    Get-Process qemu-system-x86_64 -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

Stop-Qemu; Start-Sleep -Milliseconds 400
if (Test-Path $OutPath) { Remove-Item $OutPath -Force }
$job = Start-Job -ScriptBlock {
    param($RootPath)
    powershell -ExecutionPolicy Bypass -File (Join-Path $RootPath 'scripts\run\run_uefi.ps1') -Headless -NoPassthrough -SerialTcp
} -ArgumentList $Root
Start-Sleep -Milliseconds $WaitMs
# Send screendump over the QEMU monitor (TCP 4444).
try {
    $c = [System.Net.Sockets.TcpClient]::new(); $c.Connect('127.0.0.1', 4444)
    $s = $c.GetStream()
    $cmd = "screendump $OutPath`r`n"
    $b = [System.Text.Encoding]::ASCII.GetBytes($cmd)
    $s.Write($b, 0, $b.Length); $s.Flush()
    Start-Sleep -Milliseconds 1500
    $c.Close()
} catch { Write-Host "monitor error: $_" }
Start-Sleep -Milliseconds 500
Stop-Qemu
Stop-Job $job -ErrorAction SilentlyContinue | Out-Null
Remove-Job $job -Force -ErrorAction SilentlyContinue | Out-Null
if (Test-Path $OutPath) { Write-Host ("OK screendump " + (Get-Item $OutPath).Length + " bytes -> " + $OutPath) }
else { Write-Host "NO screendump produced" }
