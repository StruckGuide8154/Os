param(
    [ValidateSet('Default', 'Cache32Max')]
    [string]$PerfProfile = 'Default',
    [string]$GuestMemory,
    [switch]$Headless,
    [switch]$SerialTcp
)

$ErrorActionPreference = 'Stop'
$Root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$QEMU = 'C:\Program Files\qemu\qemu-system-x86_64.exe'
$IMG = (Join-Path $Root 'build\GritOS.img')
$LOG = (Join-Path $Root 'serial.log')

if (-not $GuestMemory) {
    $GuestMemory = if ($PerfProfile -eq 'Cache32Max') { '32M' } else { '512M' }
}

Write-Host "Booting GritOS (BIOS) in QEMU with $PerfProfile, $GuestMemory RAM..." -ForegroundColor Cyan
$displayArg = if ($Headless) { 'none' } else { 'gtk,grab-on-hover=on,show-cursor=on,window-close=on' }
$serialArg = if ($SerialTcp) { 'tcp:127.0.0.1:5555,server=on,wait=off' } else { "file:$LOG" }
$qemuArgs = @(
    '-drive', "file=$IMG,format=raw,index=0,media=disk",
    '-m', $GuestMemory,
    '-vga', 'std',
    '-display', $displayArg,
    '-name', 'GritOS',
    '-serial', $serialArg,
    '-device', 'nec-usb-xhci,id=xhci',
    '-device', 'usb-mouse,bus=xhci.0'
)
if ($PerfProfile -eq 'Cache32Max') {
    $qemuArgs += @('-smp', '8,sockets=1,cores=8,threads=1')
}
& $QEMU @qemuArgs
