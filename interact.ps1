# NexusOS QEMU Interaction Tools
# Connects to QEMU monitor on tcp:127.0.0.1:4444
param(
    [Parameter(Position=0)]
    [string]$Action,
    [Parameter(Position=1)]
    [string]$Value
)

$MonitorHost = '127.0.0.1'
$MonitorPort = 4444
$ScreenDir   = Join-Path $PSScriptRoot 'build\screenshots'

function Send-QemuCommand([string]$cmd) {
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $client.Connect($MonitorHost, $MonitorPort)
        $stream = $client.GetStream()
        $reader = New-Object System.IO.StreamReader($stream)
        $writer = New-Object System.IO.StreamWriter($stream)
        $writer.AutoFlush = $true
        Start-Sleep -Milliseconds 200
        while ($stream.DataAvailable) { $null = $reader.ReadLine() }
        $writer.WriteLine($cmd)
        Start-Sleep -Milliseconds 300
        $response = ''
        while ($stream.DataAvailable) {
            $line = $reader.ReadLine()
            if ($line) { $response += $line + "`n" }
        }
        $client.Close()
        return $response.Trim()
    } catch {
        Write-Host "Error connecting to QEMU monitor: $_" -ForegroundColor Red
        return $null
    }
}

function Send-Key([string]$keyname) {
    Send-QemuCommand "sendkey $keyname" | Out-Null
}

function CharToKey([char]$c) {
    $code = [int]$c
    # Lowercase letters
    if ($code -ge 97 -and $code -le 122) { return [string]$c }
    # Uppercase letters
    if ($code -ge 65 -and $code -le 90) { return 'shift-' + [char]($code + 32) }
    # Digits
    if ($code -ge 48 -and $code -le 57) { return [string]$c }
    # Special chars
    switch ($c) {
        ' '  { return 'spc' }
        '.'  { return 'dot' }
        ','  { return 'comma' }
        '-'  { return 'minus' }
        '='  { return 'equal' }
        '/'  { return 'slash' }
        '\'  { return 'backslash' }
        '['  { return 'bracket_left' }
        ']'  { return 'bracket_right' }
        ';'  { return 'semicolon' }
        '`'  { return 'grave_accent' }
        '!'  { return 'shift-1' }
        '@'  { return 'shift-2' }
        '#'  { return 'shift-3' }
        '$'  { return 'shift-4' }
        '%'  { return 'shift-5' }
        '^'  { return 'shift-6' }
        '&'  { return 'shift-7' }
        '*'  { return 'shift-8' }
        '('  { return 'shift-9' }
        ')'  { return 'shift-0' }
        '_'  { return 'shift-minus' }
        '+'  { return 'shift-equal' }
        '{'  { return 'shift-bracket_left' }
        '}'  { return 'shift-bracket_right' }
        '|'  { return 'shift-backslash' }
        ':'  { return 'shift-semicolon' }
        '"'  { return 'shift-apostrophe' }
        '<'  { return 'shift-comma' }
        '>'  { return 'shift-dot' }
        '?'  { return 'shift-slash' }
        '~'  { return 'shift-grave_accent' }
        default { return $null }
    }
}

function Type-String([string]$text) {
    foreach ($c in $text.ToCharArray()) {
        $key = CharToKey $c
        if ($key) {
            Send-QemuCommand "sendkey $key" | Out-Null
            Start-Sleep -Milliseconds 50
        } else {
            Write-Host "Warning: No mapping for char '$c'" -ForegroundColor Yellow
        }
    }
}

function Take-Screenshot {
    New-Item -Path $ScreenDir -ItemType Directory -Force | Out-Null
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $ppmFile = Join-Path $ScreenDir "nexus_$timestamp.ppm"
    $pngFile = Join-Path $ScreenDir "nexus_$timestamp.png"
    $resp = Send-QemuCommand "screendump $ppmFile"
    Start-Sleep -Milliseconds 500

    if (Test-Path $ppmFile) {
        try {
            Add-Type -AssemblyName System.Drawing
            $bitmap = [System.Drawing.Image]::FromFile($ppmFile)
            $bitmap.Save($pngFile, [System.Drawing.Imaging.ImageFormat]::Png)
            $bitmap.Dispose()
            Remove-Item $ppmFile
            Write-Host "Screenshot: $pngFile" -ForegroundColor Green
            return $pngFile
        } catch {
            Write-Host "Screenshot (PPM): $ppmFile" -ForegroundColor Green
            return $ppmFile
        }
    } else {
        Write-Host 'Screenshot failed' -ForegroundColor Red
        return $null
    }
}

switch ($Action.ToLower()) {
    'screenshot' {
        Take-Screenshot | Out-Null
    }
    'type' {
        Write-Host "Typing: $Value" -ForegroundColor Cyan
        Type-String $Value
    }
    'key' {
        Write-Host "Key: $Value" -ForegroundColor Cyan
        Send-Key $Value
    }
    'cmd' {
        Write-Host "Command: $Value" -ForegroundColor Cyan
        Type-String $Value
        Start-Sleep -Milliseconds 100
        Send-Key 'ret'
        Start-Sleep -Milliseconds 1000
        Take-Screenshot | Out-Null
    }
    'send' {
        $resp = Send-QemuCommand $Value
        if ($resp) { Write-Host $resp }
    }
    default {
        Write-Host 'Usage:' -ForegroundColor Yellow
        Write-Host '  .\interact.ps1 screenshot'
        Write-Host '  .\interact.ps1 type "hello"'
        Write-Host '  .\interact.ps1 key ret'
        Write-Host '  .\interact.ps1 cmd "help"'
        Write-Host '  .\interact.ps1 send "info version"'
    }
}
