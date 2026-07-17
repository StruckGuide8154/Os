param(
    [switch]$SkipBuild,
    [int]$BootSeconds = 40,
    [string]$Qemu = 'C:\Program Files\qemu\qemu-system-x86_64.exe'
)

$ErrorActionPreference = 'Stop'
$Root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$Build = Join-Path $Root 'build'

if (-not (Test-Path -LiteralPath $Qemu)) {
    throw "QEMU not found: $Qemu"
}
if (-not $SkipBuild) {
    & (Join-Path $Root 'scripts\build\build_uefi.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'UEFI build failed' }
}

function Invoke-VirtioBoot([string]$Name, [switch]$Legacy) {
    $log = Join-Path $Build "virtio_net_$Name.log"
    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
    $dev = 'virtio-net-pci,netdev=net0'
    if ($Legacy) { $dev += ',disable-modern=on' }
    $args = @(
        '-cpu', 'max',
        '-bios', (Join-Path $Build 'OVMF.fd'),
        '-drive', "file=$(Join-Path $Build 'data.img'),format=raw,if=ide,index=0,media=disk",
        '-drive', "format=raw,file=fat:rw:$(Join-Path $Build 'esp'),if=ide,index=1,media=disk",
        '-m', '512M', '-smp', '8,sockets=1,cores=8,threads=1',
        '-vga', 'std', '-display', 'none',
        '-device', 'qemu-xhci,id=xhci0,p2=8,p3=8',
        '-device', 'usb-kbd', '-device', 'usb-mouse',
        '-netdev', 'user,id=net0', '-device', $dev,
        '-serial', "file:$log", '-no-reboot', '-monitor', 'none'
    )
    $p = Start-Process -FilePath $Qemu -ArgumentList $args -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds $BootSeconds
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force }
    $serial = Get-Content -LiteralPath $log -Raw
    foreach ($marker in @('[VNET BIND]', '[DHCP L2 DISC]', '[DHCP L2 OFFER]', '[DHCP L2 BOUND]')) {
        if (-not $serial.Contains($marker)) { throw "$Name missing $marker (see $log)" }
    }
    if ($serial.Contains('X000000000000000E@')) { throw "$Name hit a page fault (see $log)" }
    Write-Host "[virtio-net] $Name PASS"
}

Invoke-VirtioBoot -Name 'modern'
Invoke-VirtioBoot -Name 'transitional' -Legacy
Write-Host '[virtio-net] PASS'
