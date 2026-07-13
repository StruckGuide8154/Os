param(
    [switch]$SkipBuild,
    [switch]$SkipBenchmark,
    [ValidateRange(1000, 120000)]
    [int]$BootDelayMs = 30000
)

$ErrorActionPreference = 'Stop'

$Root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$BuildDir = Join-Path $Root 'build'
$LogPath = Join-Path $BuildDir 'cache32_serial.log'
$ImagePath = Join-Path $BuildDir 'Grit.img'
$SerialHost = '127.0.0.1'
$SerialPort = 5555

function Get-Cache32QemuProcess {
    # Do not kill unrelated interactive/UEFI QEMU sessions. This test owns only
    # the process whose command line has its BIOS disk image attached.
    @(Get-CimInstance Win32_Process -Filter "Name='qemu-system-x86_64.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains("file=$ImagePath") })
}

function Stop-Cache32QemuIfRunning {
    $owned = @(Get-Cache32QemuProcess)
    foreach ($process in $owned) {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
    }

    if ($owned.Count -gt 0) {
        $deadline = [DateTime]::UtcNow.AddSeconds(5)
        do {
            $remaining = @(Get-Cache32QemuProcess)
            if ($remaining.Count -eq 0) { return }
            Start-Sleep -Milliseconds 100
        } while ([DateTime]::UtcNow -lt $deadline)

        $pids = ($remaining | ForEach-Object ProcessId) -join ', '
        throw "Cache32 QEMU did not stop within 5 seconds (PID(s): $pids); refusing to rebuild a mapped image."
    }
}

function Read-Serial {
    param(
        [int]$ConnectTimeoutMs = 8000,
        [int]$CaptureMs = 14000,
        [byte[]]$CommandBytes = @()
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
        if ($CommandBytes.Count -gt 0) {
            # BIOS stage 2 reads the reserved kernel area sector-by-sector.
            # Leave enough time for the current 4 MiB reservation plus early
            # storage initialization before asking the serial console for data.
            Start-Sleep -Milliseconds $BootDelayMs
            $stream.Write($CommandBytes, 0, $CommandBytes.Count)
        }

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
    Stop-Cache32QemuIfRunning
    New-Item -ItemType Directory -Path $BuildDir -Force | Out-Null

    if (-not $SkipBuild) {
        Write-Host '[cache32] Building BIOS Cache32Max image...' -ForegroundColor Yellow
        powershell -ExecutionPolicy Bypass -File (Join-Path $Root 'scripts\build\build_bios.ps1') -PerfProfile Cache32Max
        if ($LASTEXITCODE -ne 0) {
            throw "Cache32Max BIOS build failed with exit code $LASTEXITCODE."
        }
    }
    elseif (-not (Test-Path $ImagePath)) {
        throw "-SkipBuild requested but $ImagePath does not exist."
    }

    Write-Host '[cache32] Booting strict 32MB / 8-core BIOS QEMU profile...' -ForegroundColor Yellow
    $bootJob = Start-Job -ScriptBlock {
        param($RootPath)
        powershell -ExecutionPolicy Bypass -File (Join-Path $RootPath 'scripts\run\run_bios.ps1') -PerfProfile Cache32Max -Headless -SerialTcp
    } -ArgumentList $Root

    try {
        $commands = if ($SkipBenchmark) {
            [byte[]]@(0x01,0x70,0x01,0x6D,0x01,0x73)
        } else {
            [byte[]]@(0x01,0x70,0x01,0x6D,0x01,0x73,0x01,0x62)
        }
        $serial = Read-Serial -CommandBytes $commands
    }
    finally {
        Stop-Cache32QemuIfRunning
        Wait-Job $bootJob | Out-Null
        Receive-Job $bootJob | Out-Host
        Remove-Job $bootJob
    }

    Set-Content -Path $LogPath -Value $serial

    $markers = @('CPU:', 'CACHE:', 'FREQ:', 'MEMCAP:', 'SMP:', 'BENCH:')
    if ($SkipBenchmark) {
        $markers = @($markers | Where-Object { $_ -ne 'BENCH:' })
    }
    $missing = @()
    foreach ($marker in $markers) {
        if ($serial -notlike "*$marker*") { $missing += $marker }
    }
    if ($missing.Count -gt 0) {
        Write-Host '[cache32] FAILED' -ForegroundColor Red
        Write-Host "Serial log saved to $LogPath" -ForegroundColor DarkYellow
        Write-Host 'Missing markers:' -ForegroundColor DarkYellow
        foreach ($marker in $missing) { Write-Host "  - $marker" -ForegroundColor DarkYellow }
        exit 1
    }

    Write-Host '[cache32] PASS' -ForegroundColor Green
    Write-Host "Serial log saved to $LogPath" -ForegroundColor Gray
}
finally {
    Stop-Cache32QemuIfRunning
}
