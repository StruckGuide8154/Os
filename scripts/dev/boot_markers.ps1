# Boot the already-built UEFI image headless, capture serial, and check for the
# stable late boot markers (CPU:/CACHE:/MEMCAP: + L4/X3 main-loop entry).
# Retries past the known intermittent early-boot CANARY panic (~1-in-3, PIT-IRQ
# race in the boot_anim/fat16 phase - pre-existing). Behavior-parity gate for the
# GHLK de-shim work: a clean boot must still reach these markers.
param(
    [int]$Retries = 6,
    [int]$CaptureMs = 18000
)
$ErrorActionPreference = 'Continue'
$Root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$SerialHost = '127.0.0.1'; $SerialPort = 5555
$Markers = @('CPU:', 'CACHE:', 'MEMCAP:', '[L4]', 'X3=')
$RegexMarkers = @()

function Stop-Qemu {
    try {
        $c = [System.Net.Sockets.TcpClient]::new(); $c.Connect('127.0.0.1', 4444)
        $s = $c.GetStream(); $b = [System.Text.Encoding]::ASCII.GetBytes("quit`r`n")
        $s.Write($b, 0, $b.Length); $s.Flush(); $c.Close(); Start-Sleep -Milliseconds 400
    } catch {}
    Get-Process qemu-system-x86_64 -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

function Read-Serial {
    param([int]$ConnectTimeoutMs = 6000, [int]$Cap = 18000)
    $deadline = [DateTime]::UtcNow.AddMilliseconds($ConnectTimeoutMs); $client = $null
    while (-not $client -and [DateTime]::UtcNow -lt $deadline) {
        try { $cand = [System.Net.Sockets.TcpClient]::new(); $cand.Connect($SerialHost, $SerialPort); $client = $cand }
        catch { if ($cand) { $cand.Dispose() }; Start-Sleep -Milliseconds 100 }
    }
    if (-not $client) { return '' }
    $sb = [System.Text.StringBuilder]::new(); $stream = $client.GetStream()
    $buf = New-Object byte[] 4096; $stop = [DateTime]::UtcNow.AddMilliseconds($Cap)
    while ([DateTime]::UtcNow -lt $stop) {
        if ($stream.DataAvailable) {
            $n = $stream.Read($buf, 0, $buf.Length)
            if ($n -gt 0) { [void]$sb.Append([System.Text.Encoding]::ASCII.GetString($buf, 0, $n)) }
        } else { Start-Sleep -Milliseconds 50 }
    }
    $client.Close(); return $sb.ToString()
}

for ($i = 1; $i -le $Retries; $i++) {
    Stop-Qemu; Start-Sleep -Milliseconds 500
    Write-Host "[markers] boot attempt $i/$Retries ..." -ForegroundColor Yellow
    $job = Start-Job -ScriptBlock {
        param($RootPath)
        powershell -ExecutionPolicy Bypass -File (Join-Path $RootPath 'scripts\run\run_uefi.ps1') -Headless -NoPassthrough -SerialTcp
    } -ArgumentList $Root
    try { $serial = Read-Serial -Cap $CaptureMs } finally { Stop-Job $job -ErrorAction SilentlyContinue | Out-Null; Remove-Job $job -Force -ErrorAction SilentlyContinue | Out-Null }
    Stop-Qemu
    Set-Content -Path (Join-Path $Root 'build\boot_markers_serial.log') -Value $serial
    $missing = @()
    foreach ($m in $Markers) { if ($serial -notlike "*$m*") { $missing += $m } }
    foreach ($m in $RegexMarkers) { if ($serial -notmatch $m) { $missing += $m } }
    $hadCanary = ($serial -match 'CANARY 0000000000000000')
    if ($missing.Count -eq 0) {
        Write-Host "[markers] PASS on attempt $i (all markers present)" -ForegroundColor Green
        exit 0
    }
    Write-Host ("[markers] attempt $i incomplete (missing: {0}; canary-panic={1}; bytes={2})" -f ($missing -join ','), $hadCanary, $serial.Length) -ForegroundColor DarkYellow
}
Write-Host "[markers] FAILED after $Retries attempts" -ForegroundColor Red
exit 1
