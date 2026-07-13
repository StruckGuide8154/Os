$ErrorActionPreference = 'Stop'

$Root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$BuildDir = Join-Path $Root 'build'
$LogPath = Join-Path $BuildDir 'smoke_uefi_serial.log'
$Markers = @(
    'BdsDxe: starting',
    '(!0-ENTRY)',
    'CPU:',
    'CACHE:',
    'MEMCAP:',
    '[L4]',
    'X3='
)
$RegexMarkers = @()
$SerialHost = '127.0.0.1'
$SerialPort = 5555

function Stop-QemuIfRunning {
    try {
        $client = [System.Net.Sockets.TcpClient]::new()
        $client.Connect('127.0.0.1', 4444)
        $stream = $client.GetStream()
        $bytes = [System.Text.Encoding]::ASCII.GetBytes("quit`r`n")
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush()
        $client.Close()
        Start-Sleep -Milliseconds 500
    } catch {}
    Get-Process qemu-system-x86_64 -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

function Read-SerialBootLog {
    param(
        [int]$ConnectTimeoutMs = 5000,
        [int]$CaptureMs = 16000
    )

    $deadline = [DateTime]::UtcNow.AddMilliseconds($ConnectTimeoutMs)
    $client = $null
    while (-not $client -and [DateTime]::UtcNow -lt $deadline) {
        try {
            $candidate = [System.Net.Sockets.TcpClient]::new()
            $candidate.Connect($SerialHost, $SerialPort)
            $client = $candidate
        }
        catch {
            if ($candidate) { $candidate.Dispose() }
            Start-Sleep -Milliseconds 100
        }
    }

    if (-not $client) {
        throw "Unable to connect to serial on $SerialHost`:$SerialPort"
    }

    try {
        $stream = $client.GetStream()
        $buffer = New-Object byte[] 65536
        $encoding = [System.Text.Encoding]::ASCII
        $builder = New-Object System.Text.StringBuilder
        $captureDeadline = [DateTime]::UtcNow.AddMilliseconds($CaptureMs)

        while ([DateTime]::UtcNow -lt $captureDeadline) {
            while ($stream.DataAvailable) {
                $count = $stream.Read($buffer, 0, $buffer.Length)
                if ($count -le 0) { break }
                [void]$builder.Append($encoding.GetString($buffer, 0, $count))
            }
            Start-Sleep -Milliseconds 50
        }

        return $builder.ToString()
    }
    finally {
        $client.Close()
    }
}

try {
    Stop-QemuIfRunning
    Start-Sleep -Seconds 1

    Write-Host '[smoke] Building UEFI image...' -ForegroundColor Yellow
    powershell -ExecutionPolicy Bypass -File (Join-Path $Root 'scripts\build\build_uefi.ps1')

    Write-Host '[smoke] Booting VM and capturing serial...' -ForegroundColor Yellow
    $bootJob = Start-Job -ScriptBlock {
        param($RootPath)
        powershell -ExecutionPolicy Bypass -File (Join-Path $RootPath 'scripts\run\run_uefi.ps1') -Headless -NoPassthrough -SerialTcp
    } -ArgumentList $Root

    try {
        $serial = Read-SerialBootLog
    }
    finally {
        Wait-Job $bootJob | Out-Null
        Receive-Job $bootJob | Out-Host
        Remove-Job $bootJob
    }

    $null = New-Item -ItemType Directory -Path $BuildDir -Force
    Set-Content -Path $LogPath -Value $serial

    $missing = @()
    foreach ($marker in $Markers) {
        if ($serial -notlike "*$marker*") {
            $missing += $marker
        }
    }
    foreach ($marker in $RegexMarkers) {
        if ($serial -notmatch $marker) {
            $missing += $marker
        }
    }

    if ($missing.Count -gt 0) {
        Write-Host '[smoke] FAILED' -ForegroundColor Red
        Write-Host "Serial log saved to $LogPath" -ForegroundColor DarkYellow
        Write-Host 'Missing markers:' -ForegroundColor DarkYellow
        foreach ($marker in $missing) {
            Write-Host "  - $marker" -ForegroundColor DarkYellow
        }
        exit 1
    }

    Write-Host '[smoke] PASS' -ForegroundColor Green
    Write-Host "Serial log saved to $LogPath" -ForegroundColor Gray
}
finally {
    Stop-QemuIfRunning
}
