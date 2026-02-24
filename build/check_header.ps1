$b = [System.IO.File]::ReadAllBytes('C:\Users\user\Documents\new\build\screen.ppm')
Write-Host "File size:" $b.Length "bytes"
for ($i = 0; $i -lt 20; $i++) {
    Write-Host ("Byte {0}: 0x{1:X2} char='{2}'" -f $i, $b[$i], [char]$b[$i])
}
# The PPM header is "P6\n1024 768\n255\n" = 3+5+4+4 = 16 bytes
# P(50) 6(36) LF(0A) 1(31) 0(30) 2(32) 4(34) SP(20) 7(37) 6(36) 8(38) LF(0A) 2(32) 5(35) 5(35) LF(0A)
# That's 16 bytes of header, pixel data starts at offset 16
$h = 16
# Check a few known pixels
# desktop bg at (800,300) should be 0x335577
$o = $h + (300 * 1024 + 800) * 3
Write-Host ("Pixel (800,300): R={0:X2} G={1:X2} B={2:X2}" -f $b[$o], $b[$o+1], $b[$o+2])
# Center (512,384)
$o = $h + (384 * 1024 + 512) * 3
Write-Host ("Pixel (512,384): R={0:X2} G={1:X2} B={2:X2}" -f $b[$o], $b[$o+1], $b[$o+2])
# Pure desktop (950,600)
$o = $h + (600 * 1024 + 950) * 3
Write-Host ("Pixel (950,600): R={0:X2} G={1:X2} B={2:X2}" -f $b[$o], $b[$o+1], $b[$o+2])
