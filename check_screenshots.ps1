# Check if screenshots exist and their sizes
foreach ($f in @('before_drag.ppm', 'during_drag.ppm', 'after_drag.ppm')) {
    $path = "C:\Users\user\Documents\new\build\$f"
    if (Test-Path $path) {
        $size = (Get-Item $path).Length
        Write-Host "$f : $size bytes"

        # Read a few pixels to check content
        $bytes = [IO.File]::ReadAllBytes($path)
        # PPM header is "P6\n1024 768\n255\n" = about 15 bytes
        # Find end of header
        $headerEnd = 0
        $newlines = 0
        for ($i = 0; $i -lt 50; $i++) {
            if ($bytes[$i] -eq 10) { $newlines++ }
            if ($newlines -eq 3) { $headerEnd = $i + 1; break }
        }

        # Check pixel at center of screen (512, 384) - offset = headerEnd + (384*1024+512)*3
        $offset = $headerEnd + (384 * 1024 + 512) * 3
        $r = $bytes[$offset]
        $g = $bytes[$offset + 1]
        $b = $bytes[$offset + 2]
        Write-Host "  Center pixel: R=$r G=$g B=$b"

        # Check pixel at taskbar area (35, 748)
        $offset = $headerEnd + (748 * 1024 + 35) * 3
        $r = $bytes[$offset]
        $g = $bytes[$offset + 1]
        $b = $bytes[$offset + 2]
        Write-Host "  Taskbar area (35,748): R=$r G=$g B=$b"

        # Check pixel where window might be (350, 160)
        $offset = $headerEnd + (160 * 1024 + 350) * 3
        $r = $bytes[$offset]
        $g = $bytes[$offset + 1]
        $b = $bytes[$offset + 2]
        Write-Host "  Window area (350,160): R=$r G=$g B=$b"
    } else {
        Write-Host "$f : NOT FOUND"
    }
}
