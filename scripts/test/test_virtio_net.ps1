param(
    [switch]$SkipBuild,
    [ValidateSet('Modern', 'Legacy')]
    [string]$Transport = 'Modern',
    [int]$BootTimeoutSeconds = 30,
    [int]$NetworkTimeoutSeconds = 20
)

$ErrorActionPreference = 'Stop'
$Root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$Run = Join-Path $Root 'scripts\run\run_uefi.ps1'
$Build = Join-Path $Root 'scripts\build\build_uefi.ps1'
$Log = Join-Path $Root 'build\virtio_net_serial.log'
$launcher = $null
$client = $null

function Read-AvailableSerial {
    param([IO.Stream]$Stream, [byte[]]$Buffer, [ref]$Text)
    while ($Stream.DataAvailable) {
        $n = $Stream.Read($Buffer, 0, $Buffer.Length)
        if ($n -gt 0) {
            $Text.Value += [Text.Encoding]::ASCII.GetString($Buffer, 0, $n)
        }
    }
}

try {
    if (-not $SkipBuild) {
        & $Build
        if ($LASTEXITCODE -ne 0) { throw "UEFI build failed: $LASTEXITCODE" }
    }

    Get-Process qemu-system-x86_64 -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue

    $emulatedNic = if ($Transport -eq 'Modern') { 'VirtIOModern' } else { 'VirtIO' }
    $launcher = Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $Run,
        '-Headless', '-NoPassthrough', '-SerialTcp', '-EmulatedNic', $emulatedNic
    )

    $client = [Net.Sockets.TcpClient]::new()
    $deadline = (Get-Date).AddSeconds(20)
    while (-not $client.Connected -and (Get-Date) -lt $deadline) {
        try { $client.Connect('127.0.0.1', 5555) }
        catch { Start-Sleep -Milliseconds 250 }
    }
    if (-not $client.Connected) { throw 'QEMU serial TCP endpoint did not open' }

    $stream = $client.GetStream()
    $buffer = [byte[]]::new(8192)
    $serial = ''
    $deadline = (Get-Date).AddSeconds($BootTimeoutSeconds)
    while ((Get-Date) -lt $deadline -and $serial -notmatch '\[/BOOTTIME\]') {
        Read-AvailableSerial $stream $buffer ([ref]$serial)
        Start-Sleep -Milliseconds 100
    }
    if ($serial -notmatch '\[VNET READY\]') { throw 'VirtIO-net did not become ready' }
    $transportMarker = if ($Transport -eq 'Modern') { '[VNET MODERN]' } else { '[VNET LEGACY]' }
    if (-not $serial.Contains($transportMarker)) { throw "missing transport marker: $transportMarker" }

    # COM1 automation protocol: 0x01 arms the next byte as a control command;
    # 'i' runs DHCP followed by an ICMP echo to 8.8.8.8.
    $stream.Write([byte[]](1, [byte][char]'i'), 0, 2)
    $stream.Flush()
    $deadline = (Get-Date).AddSeconds($NetworkTimeoutSeconds)
    while ((Get-Date) -lt $deadline -and $serial -notmatch '\[NETPING (OK|FAIL)\]') {
        Read-AvailableSerial $stream $buffer ([ref]$serial)
        Start-Sleep -Milliseconds 100
    }
    Read-AvailableSerial $stream $buffer ([ref]$serial)
    Set-Content -LiteralPath $Log -Value $serial -Encoding ASCII

    $required = @('[DHCP ACK]', '[ARP OK]', '[ICMP OK]', '[NETPING OK]')
    foreach ($marker in $required) {
        if (-not $serial.Contains($marker)) { throw "missing serial marker: $marker" }
    }
    if ($serial -match 'PANIC|EXC:|TRIPLE FAULT') { throw 'guest fault marker found' }

    Write-Host "[virtio-net] PASS: ready + DHCP + ARP + ICMP over $Transport VirtIO PCI" -ForegroundColor Green
    Write-Host "[virtio-net] serial: $Log"
}
finally {
    if ($client) { $client.Dispose() }
    Get-Process qemu-system-x86_64 -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    if ($launcher -and -not $launcher.HasExited) {
        Stop-Process -Id $launcher.Id -Force -ErrorAction SilentlyContinue
    }
}
