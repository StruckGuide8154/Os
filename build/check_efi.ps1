# Check EFI binary at the crash offset
$b = [System.IO.File]::ReadAllBytes('C:\Users\user\Documents\new\build\esp\EFI\BOOT\BOOTX64.EFI')
Write-Host "EFI size: $($b.Length) bytes"

# The crash was at RIP 0x10144B
# Image base = 0x100000, .text VA = 0x1000, .text file offset = 0x200
# So RIP 0x10144B: VA offset = 0x10144B - 0x100000 = 0x144B
# File offset = 0x144B - 0x1000 + 0x200 = 0x064B
$fileOff = 0x064B
Write-Host "Checking file offset 0x$($fileOff.ToString('X4')):"
Write-Host "Bytes: $($b[$fileOff].ToString('X2')) $($b[$fileOff+1].ToString('X2')) $($b[$fileOff+2].ToString('X2')) $($b[$fileOff+3].ToString('X2')) $($b[$fileOff+4].ToString('X2')) $($b[$fileOff+5].ToString('X2')) $($b[$fileOff+6].ToString('X2')) $($b[$fileOff+7].ToString('X2'))"

# Also dump around the load_kernel area - let's check a wider range
# The _start begins at file offset 0x200 (TEXT section)
for ($off = 0x0640; $off -lt 0x0670; $off += 16) {
    $hex = ""
    for ($i = 0; $i -lt 16; $i++) {
        $hex += "$($b[$off+$i].ToString('X2')) "
    }
    Write-Host "$($off.ToString('X4')): $hex"
}
