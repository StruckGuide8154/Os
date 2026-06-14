param([string]$Tag = 'A', [int]$Port = 4460, [int]$WaitSec = 22)
$ErrorActionPreference = 'Continue'
$b = 'C:\Users\user\Documents\new\build'
$QEMU = 'C:\Program Files\qemu\qemu-system-x86_64.exe'
$serial = "$b\agent2_serial_$Tag.log"
$shot = "$b\agent2_shot_$Tag.ppm"
Remove-Item $serial, $shot -ErrorAction SilentlyContinue

$args = @(
  '-bios', "$b\OVMF.fd",
  '-drive', "format=raw,file=fat:rw:$b\esp,if=ide,index=1,media=disk",
  '-m', '512M', '-smp', '8,sockets=1,cores=8,threads=1',
  '-cpu', 'qemu64,+smep,+smap',
  '-vga', 'std',
  '-drive', "file=$b\data.img,format=raw,if=ide,index=0,media=disk",
  '-display', 'gtk,grab-on-hover=on,show-cursor=on,window-close=on',
  '-device', 'qemu-xhci,id=xhci0,p2=8,p3=8',
  '-netdev', 'user,id=net0', '-device', 'rtl8139,netdev=net0',
  '-device', 'usb-mouse,bus=xhci0.0,port=4',
  '-device', 'usb-kbd,bus=xhci0.0,port=5',
  '-serial', "file:$serial",
  '-no-reboot',
  '-monitor', "telnet:127.0.0.1:$Port,server,nowait",
  '-name', "dbg$Tag"
)
$p = Start-Process -FilePath $QEMU -ArgumentList $args -PassThru
Write-Host "QEMU pid=$($p.Id) tag=$Tag port=$Port"
$deadline = (Get-Date).AddSeconds($WaitSec)
while ((Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }

try {
  $c = New-Object System.Net.Sockets.TcpClient('127.0.0.1', $Port)
  $s = $c.GetStream(); $w = New-Object System.IO.StreamWriter($s); $w.AutoFlush = $true
  Start-Sleep -Milliseconds 300
  $w.WriteLine("screendump $shot")
  Start-Sleep -Seconds 2
  $w.Close(); $c.Close()
} catch { Write-Host "monitor error: $_" }

Start-Sleep -Milliseconds 500
if (Test-Path $shot) {
  $fs = [System.IO.File]::OpenRead($shot)
  $buf = New-Object byte[] 64
  $null = $fs.Read($buf, 0, 64); $fs.Close()
  $hdr = [System.Text.Encoding]::ASCII.GetString($buf)
  $m = [regex]::Match($hdr, 'P6\s+(\d+)\s+(\d+)')
  if ($m.Success) { Write-Host "RESULT[$Tag] dims = $($m.Groups[1].Value) x $($m.Groups[2].Value)" }
  else { Write-Host "RESULT[$Tag] could not parse PPM header: $($hdr.Substring(0,20))" }
} else { Write-Host "RESULT[$Tag] no screendump produced" }

if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
Write-Host "[$Tag] done; serial=$serial shot=$shot"
