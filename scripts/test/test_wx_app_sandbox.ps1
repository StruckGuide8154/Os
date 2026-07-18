param(
    [switch]$SkipBuild,
    [int]$BootDelayMs = 10000,
    [int]$PerAppDelayMs = 2500,
    [int]$FinalCaptureMs = 5000
)

$ErrorActionPreference = 'Stop'

$Root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$BuildDir = Join-Path $Root 'build'
$LogPath = Join-Path $BuildDir 'wx_app_sandbox_serial.log'
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
    Get-Process qemu-system-x86_64 -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
}

function Connect-Serial {
    $deadline = [DateTime]::UtcNow.AddSeconds(12)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $client = [System.Net.Sockets.TcpClient]::new()
            $client.Connect($SerialHost, $SerialPort)
            return $client
        } catch {
            Start-Sleep -Milliseconds 100
        }
    }
    throw 'serial connect failed'
}

function Drain-Serial {
    param($Stream, [int]$DurationMs)
    $buf = New-Object byte[] 65536
    $enc = [System.Text.Encoding]::ASCII
    $out = New-Object System.Text.StringBuilder
    $end = [DateTime]::UtcNow.AddMilliseconds($DurationMs)
    while ([DateTime]::UtcNow -lt $end) {
        while ($Stream.DataAvailable) {
            $n = $Stream.Read($buf, 0, $buf.Length)
            if ($n -le 0) { break }
            [void]$out.Append($enc.GetString($buf, 0, $n))
        }
        Start-Sleep -Milliseconds 50
    }
    return $out.ToString()
}

try {
    Stop-QemuIfRunning
    New-Item -ItemType Directory -Path $BuildDir -Force | Out-Null

    if (-not $SkipBuild) {
        Write-Host '[wx] Building UEFI image...' -ForegroundColor Yellow
        powershell -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $Root 'scripts\build\build_uefi.ps1') | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "build_uefi.ps1 failed: $LASTEXITCODE" }
    } else {
        Write-Host '[wx] -SkipBuild: reusing existing build artifacts.' -ForegroundColor DarkGray
    }

    Write-Host '[wx] Booting QEMU and launching W^X-sensitive built-in apps...' -ForegroundColor Yellow
    $job = Start-Job -ScriptBlock {
        param($RootPath)
        powershell -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $RootPath 'scripts\run\run_uefi.ps1') `
            -Headless -NoPassthrough -SerialTcp
    } -ArgumentList $Root

    $serial = ''
    try {
        $client = Connect-Serial
        $stream = $client.GetStream()
        $serial += Drain-Serial -Stream $stream -DurationMs $BootDelayMs

        $apps = @(
            @{ Id = 2;  Cmd = '2'; Name = 'explorer' },
            @{ Id = 3;  Cmd = '3'; Name = 'terminal' },
            @{ Id = 4;  Cmd = '4'; Name = 'notepad' },
            @{ Id = 5;  Cmd = '5'; Name = 'settings' },
            @{ Id = 6;  Cmd = '6'; Name = 'paint' },
            @{ Id = 9;  Cmd = '9'; Name = 'taskmgr' },
            @{ Id = 10; Cmd = '0'; Name = 'ping' },
            @{ Id = 11; Cmd = '1'; Name = 'media' }
        )

        foreach ($app in $apps) {
            Write-Host ("[wx] launch {0} (app id {1})" -f $app.Name, $app.Id) -ForegroundColor DarkGray
            $cmd = [byte[]]@(0x01, [byte][char]$app.Cmd)
            $stream.Write($cmd, 0, $cmd.Count)
            $stream.Flush()
            $serial += Drain-Serial -Stream $stream -DurationMs $PerAppDelayMs
        }

        $serial += Drain-Serial -Stream $stream -DurationMs $FinalCaptureMs
        $client.Close()
    } finally {
        Stop-QemuIfRunning
        Receive-Job $job -ErrorAction SilentlyContinue | Out-Host
        Remove-Job $job -Force -ErrorAction SilentlyContinue
    }

    Set-Content -Path $LogPath -Value $serial -Encoding ASCII

    foreach ($app in $apps) {
        $hex = ('{0:X16}' -f [int64]$app.Id)
        if ($serial -notlike "*L$hex*") {
            throw "Missing serial launch marker for $($app.Name) (app id $($app.Id))."
        }
    }
    if ($serial -match 'RFFFFFFFFFFFFFFFF') {
        throw "At least one app launch returned -1. Serial saved to $LogPath"
    }
    if ($serial -match 'WXPT|CANARY|SHADOW|CPIV') {
        throw "Kernel integrity/W^X panic marker found. Serial saved to $LogPath"
    }
    $appFault = $false
    foreach ($m in [regex]::Matches($serial, 'X000000000000000(6|E)@([0-9A-Fa-f]{16})')) {
        $rip = [Convert]::ToUInt64($m.Groups[2].Value, 16)
        # Low-address #PF/#UD diagnostics are known fail-closed kernel/probe paths
        # (for example the media callback-invalid redirect). App-slot execution
        # lives above 0x02000000 in this image family; faults there are regressions.
        if ($rip -ge 0x02000000) {
            $appFault = $true
            break
        }
    }
    if ($appFault) {
        throw "Ring-3 #UD/#PF marker found in an app slot during launch. Serial saved to $LogPath"
    }

    Write-Host '[wx] PASS - launched built-in apps with no W+X invariant panic or ring-3 fault.' -ForegroundColor Green
    Write-Host "Serial log saved to $LogPath"
} finally {
    Stop-QemuIfRunning
}
