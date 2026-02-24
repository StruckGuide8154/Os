# Use NASM to create a listing file
& 'C:\Tools\nasm-2.16.03\nasm.exe' -f bin -l 'C:\Users\user\Documents\new\build\uefi_loader.lst' 'C:\Users\user\Documents\new\src\boot\uefi_loader.asm'
Write-Host "Listing generated"
