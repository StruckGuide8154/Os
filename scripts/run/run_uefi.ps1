param(
    [ValidateSet('Default', 'Cache32Max')]
    [string]$PerfProfile = 'Default',
    [string]$GuestMemory,
    [switch]$Headless,
    [switch]$SerialTcp,
    [ValidateSet('User', 'Tap')]
    [string]$NetworkMode = 'User',
    [string]$TapIfName = 'OpenVPN TAP-Windows6',
    # USB passthrough: pass real host USB devices into the guest. Requires
    # WinUSB driver bound via Zadig AND elevated PowerShell.
    # Defaults to ON with the lab's known VID/PIDs (RTL8156 NIC + Lenovo mouse);
    # pass -NoPassthrough to fall back to fully emulated USB.
    # Use -NoNicPassthrough or -NoMousePassthrough to disable only one device.
    [switch]$NoPassthrough,
    [switch]$NoNicPassthrough,
    [switch]$NoMousePassthrough,
    [string]$UsbVendorId   = '0x0BDA',  # RTL8156 NIC
    [string]$UsbProductId  = '0x8156',
    [string]$MouseVendorId = '0x17EF',  # Lenovo Optical Mouse
    [string]$MouseProductId= '0x602E',
    # MSC write-back development harness. When -MscTest is given, attach
    # build/data.img as a USB Mass Storage device on the xHCI bus so the
    # kernel's MSC stack has something to enumerate, AND drop the legacy
    # if=ide data.img so ATA-PIO can't shortcut the test path.
    [switch]$MscTest,
    # Diagnostic: log every exception/interrupt and CPU reset to
    # build\qemu_int.log so a guest triple-fault (which -no-reboot turns into a
    # QEMU exit) leaves a vector + RIP trail behind. Off by default.
    [switch]$IntLog
)
$UsbPassthrough       = -not ($NoPassthrough -or $NoNicPassthrough)
$UsbMousePassthrough  = -not ($NoPassthrough -or $NoMousePassthrough)

$ErrorActionPreference = 'SilentlyContinue'

# USB passthrough on Windows needs Administrator (libusb claims the device).
# If passthrough is on and we're not elevated, re-launch ourselves elevated and exit.
if ($UsbPassthrough -or $UsbMousePassthrough) {
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Host "Passthrough requires admin - re-launching elevated..." -ForegroundColor Yellow
        $argList = @('-NoProfile','-ExecutionPolicy','Bypass','-File', $PSCommandPath)
        foreach ($kv in $PSBoundParameters.GetEnumerator()) {
            $argList += "-$($kv.Key)"
            if ($kv.Value -isnot [switch]) { $argList += "$($kv.Value)" }
        }
        Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Verb RunAs
        exit 0
    }
}

$Root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$QEMU = 'C:\Program Files\qemu\qemu-system-x86_64.exe'
$BUILD = Join-Path $Root 'build'
$SERIAL_HOST = '127.0.0.1'
$SERIAL_PORT = 5555
$SERIAL = if ($SerialTcp) { "tcp:$SERIAL_HOST`:$SERIAL_PORT,server=on,wait=off" } else { "file:$BUILD\serial_full.log" }

# Kill existing
Get-Process qemu-system-x86_64 -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

Start-Sleep -Seconds 1

# Cache32Max constrains the *allocator* to CACHE32_RAM_LIMIT (32 MiB) in
# software; it is NOT a QEMU RAM size. The kernel's static memory layout
# (wallpaper caches at 0x3000000, BACK_BUFFER_SAVE_ADDR at 0x4C00000, ...)
# reaches ~76 MiB, so the guest must still be given enough physical RAM to
# load. 36M is far too small - the kernel never loads and the firmware
# faults with #UD. 256M is comfortably above the kernel's footprint plus
# OVMF overhead.
if (-not $GuestMemory) {
    $GuestMemory = if ($PerfProfile -eq 'Cache32Max') { '256M' } else { '512M' }
}

Write-Host "Launching NexusOS UEFI with XHCI+HID ($PerfProfile, $GuestMemory RAM, net=$NetworkMode)..." -ForegroundColor Cyan

$qemuArgs = @(
    '-bios', "$BUILD\OVMF.fd",
    '-drive', "format=raw,file=fat:rw:$BUILD\esp,if=ide,index=1,media=disk",
    '-m', $GuestMemory,
    '-smp', '8,sockets=1,cores=8,threads=1',
    # Expose SMEP/SMAP so the kernel's (default-on) stac/clac user-access
    # brackets are valid instructions under TCG; without this the default
    # qemu64 model lacks SMAP and the first bracketed user deref #UDs.
    '-cpu', 'qemu64,+smep,+smap',
    '-vga', 'std'
)
if (-not $MscTest) {
    # Legacy QEMU dev path: data.img on IDE for ATA-PIO fallback.
    $qemuArgs += @('-drive', "file=$BUILD\data.img,format=raw,if=ide,index=0,media=disk")
} else {
    Write-Host "MSC test mode: data.img attached as usb-storage (no IDE fallback)." -ForegroundColor Magenta
}
$displayArg = if ($Headless) { 'none' } else { 'gtk,grab-on-hover=on,show-cursor=on,window-close=on' }
# qemu-xhci with explicit p2=USB2/p3=USB3 port counts. Default is 4/4, which
# leaves only ports 1..4 for USB2 devices and 5..8 for USB3. Bumping both to
# 8 each gives ports 1..16 so we can layout passthrough+emulated together.
$qemuArgs += @(
    '-display', $displayArg,
    '-device', 'qemu-xhci,id=xhci0,p2=8,p3=8'
)
if ($NetworkMode -eq 'Tap') {
    $qemuArgs += @(
        '-netdev', "tap,id=net0,ifname=$TapIfName",
        '-device', 'rtl8139,netdev=net0'
    )
} else {
    $qemuArgs += @(
        '-netdev', 'user,id=net0',
        '-device', 'rtl8139,netdev=net0'
    )
}
# USB device layout. Ports 1..8 are USB2; ports 9..16 are USB3 (with p2=8,p3=8
# above). RTL8156 is a SuperSpeed device — pass it through on a USB3 port.
# Mouse is usually USB2/LowSpeed — keep it on a USB2 port. Order on the bus
# determines enumeration order the guest sees.
if ($UsbPassthrough) {
    if (-not $UsbVendorId -or -not $UsbProductId) {
        Write-Host "UsbPassthrough requires -UsbVendorId and -UsbProductId (e.g. 0x0BDA 0x8156)." -ForegroundColor Red
        exit 1
    }
    Write-Host "USB passthrough (NIC): vendor=$UsbVendorId product=$UsbProductId (auto port)." -ForegroundColor Yellow
    Write-Host "  Host device must be bound to WinUSB via Zadig (admin)." -ForegroundColor DarkYellow
    # No explicit bus=/port= — explicit port=9 errors "not found (in use?)".
    # QEMU picks the correct USB3 port for the SuperSpeed device automatically.
    $qemuArgs += @(
        '-device', "usb-host,vendorid=$UsbVendorId,productid=$UsbProductId"
    )
}
if ($UsbMousePassthrough) {
    if (-not $MouseVendorId -or -not $MouseProductId) {
        Write-Host "UsbMousePassthrough requires -MouseVendorId and -MouseProductId (e.g. 0x046d 0xc077)." -ForegroundColor Red
        exit 1
    }
    Write-Host "USB passthrough (mouse): vendor=$MouseVendorId product=$MouseProductId (auto port)." -ForegroundColor Yellow
    Write-Host "  Host device must be bound to WinUSB via Zadig (admin)." -ForegroundColor DarkYellow
    $qemuArgs += @(
        '-device', "usb-host,vendorid=$MouseVendorId,productid=$MouseProductId"
    )
} else {
    # Emulated mouse on USB2 port 1. usb-mouse is the only pointing device the
    # in-tree HID driver enumerates cleanly; usb-tablet crashes mouse_init.
    # Note: usb-mouse is relative, so the guest cursor only moves after you
    # click into the QEMU window to grab input (or hover, with grab-on-hover).
    $qemuArgs += @(
        '-device', 'usb-mouse,bus=xhci0.0,port=1'
    )
}
# Always provide a working keyboard. When passthrough is on, ports get
# auto-assigned and explicit port=N collides ("not found (in use?)"), so let
# QEMU pick a free USB2 port when any usb-host device is present.
if ($UsbPassthrough -or $UsbMousePassthrough) {
    $qemuArgs += @('-device', 'usb-kbd')
} else {
    $qemuArgs += @('-device', 'usb-kbd,bus=xhci0.0,port=2')
}
if ($MscTest) {
    # USB Mass Storage backing for ramdisk write-back development. The drive
    # is the same data.img the kernel currently treats as a RAM-resident
    # FAT16 image — once the MSC stack lands, ramdisk_flush will write
    # dirty pages back through this device instead of dropping them.
    $qemuArgs += @(
        '-drive', "if=none,id=msc0,format=raw,file=$BUILD\data.img",
        '-device', 'usb-storage,bus=xhci0.0,port=3,drive=msc0,removable=on'
    )
}
$qemuArgs += @(
    '-serial', $SERIAL,
    '-no-reboot',
    '-monitor', 'telnet:127.0.0.1:4444,server,nowait',
    '-name', 'NexusOS_UEFI'
)
if ($IntLog) {
    Write-Host "Interrupt/reset logging -> $BUILD\qemu_int.log" -ForegroundColor Yellow
    $qemuArgs += @('-d', 'int,cpu_reset,guest_errors', '-D', "$BUILD\qemu_int.log")
}
# Diagnostics for USB passthrough — logs every libusb open/claim attempt.
if ($UsbPassthrough -or $UsbMousePassthrough) {
    $qemuArgs += @(
        '-trace', 'usb_host_open_started',
        '-trace', 'usb_host_open_success',
        '-trace', 'usb_host_open_failure',
        '-trace', 'usb_host_claim_interfaces',
        '-trace', 'usb_host_release_interfaces',
        '-trace', 'usb_host_attach_kernel',
        '-trace', 'usb_host_detach_kernel',
        '-trace', 'usb_host_reset',
        '-trace', 'usb_host_disconnect',
        '-d', 'trace:usb_host_*',
        '-D', "$BUILD\qemu_usb.log"
    )
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Host "WARNING: usb-host on Windows needs Administrator. You are running as a normal user." -ForegroundColor Red
        Write-Host "  Right-click PowerShell -> Run as administrator, then re-run this script." -ForegroundColor Red
    }
    Write-Host "USB trace log: $BUILD\qemu_usb.log" -ForegroundColor Cyan
}

$proc = Start-Process -FilePath $QEMU -ArgumentList $qemuArgs -PassThru

Start-Sleep -Milliseconds 800
if ($proc.HasExited) {
    Write-Host "QEMU exited early." -ForegroundColor Red
    exit 1
}

if ($SerialTcp) {
    $ready = $false
    for ($i = 0; $i -lt 20; $i++) {
        try {
            $client = [System.Net.Sockets.TcpClient]::new()
            $client.Connect($SERIAL_HOST, $SERIAL_PORT)
            $client.Close()
            $ready = $true
            break
        } catch {
            Start-Sleep -Milliseconds 250
        }
    }

    if (-not $ready) {
        Write-Host "QEMU running, serial not ready." -ForegroundColor Yellow
        exit 2
    }

    Write-Host "VM running, serial ready on $SERIAL_HOST`:$SERIAL_PORT" -ForegroundColor Green
} else {
    Write-Host "VM running, serial logging to $BUILD\serial_full.log" -ForegroundColor Green
}
