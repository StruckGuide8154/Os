# NexusOS Quick Interaction - All-in-one: send command + screenshot + convert + output path
# Usage: .\q.ps1 "command"       - Send command, screenshot, convert, output PNG path
#        .\q.ps1 -s              - Screenshot only
#        .\q.ps1 -k "ret"        - Send single key
#        .\q.ps1 -r              - Rebuild + restart QEMU
param(
    [Parameter(Position=0)][string]$Cmd,
    [switch]$s,
    [string]$k,
    [switch]$r
)

$H = '127.0.0.1'; $P = 4444
$SD = Join-Path $PSScriptRoot 'build\screenshots'
New-Item -Path $SD -ItemType Directory -Force | Out-Null

function Q([string]$c) {
    try {
        $t = New-Object System.Net.Sockets.TcpClient; $t.Connect($H,$P)
        $st = $t.GetStream(); $rd = New-Object System.IO.StreamReader($st)
        $wr = New-Object System.IO.StreamWriter($st); $wr.AutoFlush = $true
        Start-Sleep -Milliseconds 150
        while($st.DataAvailable){$null=$rd.ReadLine()}
        $wr.WriteLine($c); Start-Sleep -Milliseconds 200
        $o=''; while($st.DataAvailable){$l=$rd.ReadLine();if($l){$o+=$l+"`n"}}
        $t.Close(); return $o.Trim()
    } catch { return $null }
}

function CK([char]$c) {
    $n=[int]$c
    if($n -ge 97 -and $n -le 122){return [string]$c}
    if($n -ge 65 -and $n -le 90){return 'shift-'+[char]($n+32)}
    if($n -ge 48 -and $n -le 57){return [string]$c}
    switch($c){' '{'spc'}'.'{'dot'}','{'comma'}'-'{'minus'}'='{'equal'}
    '/'{'slash'}'\'{'backslash'}'['{'bracket_left'}']'{'bracket_right'}
    ';'{'semicolon'}'`'{'grave_accent'}'!'{'shift-1'}'@'{'shift-2'}
    '#'{'shift-3'}'$'{'shift-4'}'%'{'shift-5'}'^'{'shift-6'}'&'{'shift-7'}
    '*'{'shift-8'}'('{'shift-9'}')'{'shift-0'}'_'{'shift-minus'}
    '+'{'shift-equal'}'{'{'shift-bracket_left'}'}'{'shift-bracket_right'}
    '|'{'shift-backslash'}':'{'shift-semicolon'}'"'{'shift-apostrophe'}
    '<'{'shift-comma'}'>'{'shift-dot'}'?'{'shift-slash'} "'"{'apostrophe'}
    '~'{'shift-grave_accent'} default{$null}}
}

function TY([string]$txt) {
    foreach($c in $txt.ToCharArray()){$k=CK $c;if($k){Q "sendkey $k"|Out-Null;Start-Sleep -Milliseconds 10}}
}

function SS {
    $ts = Get-Date -Format 'yyyyMMdd_HHmmss'
    $pf = Join-Path $SD "n_$ts.ppm"
    $pg = Join-Path $SD "nexus_latest.png"
    Q "screendump $pf" | Out-Null
    Start-Sleep -Milliseconds 400
    if(Test-Path $pf){
        try {
            Add-Type -AssemblyName System.Drawing -ErrorAction Stop
            $b=[System.IO.File]::ReadAllBytes($pf);$he=0;$lc=0
            for($i=0;$i -lt $b.Length;$i++){if($b[$i]-eq 10){$lc++;if($lc-eq 3){$he=$i+1;break}}}
            $hdr=[System.Text.Encoding]::ASCII.GetString($b,0,$he).Split("`n")
            $d=$hdr[1].Split(' ');$w=[int]$d[0];$h=[int]$d[1]
            $bmp=New-Object System.Drawing.Bitmap($w,$h)
            $o=$he;for($y=0;$y -lt $h;$y++){for($x=0;$x -lt $w;$x++){
                $bmp.SetPixel($x,$y,[System.Drawing.Color]::FromArgb($b[$o],$b[$o+1],$b[$o+2]));$o+=3}}
            $bmp.Save($pg,[System.Drawing.Imaging.ImageFormat]::Png);$bmp.Dispose()
            Remove-Item $pf -ErrorAction SilentlyContinue
            return $pg
        } catch { return $pf }
    }
    return $null
}

# Rebuild + restart
if($r) {
    Get-Process qemu* -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep 1
    powershell -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'build_uefi.ps1')
    $fw = 'C:\Program Files\qemu\share\edk2-x86_64-code.fd'
    $espPath = Join-Path $PSScriptRoot 'build\esp'
    $dataImg = Join-Path $PSScriptRoot 'build\data.img'
    Start-Process -FilePath 'C:\Program Files\qemu\qemu-system-x86_64.exe' -ArgumentList @(
        '-drive', "`"if=pflash,format=raw,readonly=on,file=$fw`"",
        '-drive', "`"file=fat:rw:$espPath,if=ide,index=0`"",
        '-drive', "`"file=$dataImg,format=raw,if=ide,index=1`"",
        '-m','512M','-net','none','-vga','std',
        '-serial','file:build/serial.log',
        '-monitor','tcp:127.0.0.1:4444,server,nowait',
        '-name','NexusOS'
    )
    Write-Host 'Rebuilding and restarting QEMU...'
    Start-Sleep 2
    $f = SS
    if($f){Write-Host "READY: $f"}
    exit 0
}

# Screenshot only
if($s) { $f=SS; if($f){Write-Host $f}; exit 0 }

# Single key
if($k) { Q "sendkey $k" | Out-Null; Start-Sleep -Milliseconds 300; $f=SS; if($f){Write-Host $f}; exit 0 }

# Send command
if($Cmd) {
    TY $Cmd
    Start-Sleep -Milliseconds 80
    Q 'sendkey ret' | Out-Null
    Start-Sleep -Milliseconds 800
    $f = SS
    if($f){Write-Host $f}
    exit 0
}

Write-Host 'Usage: .\q.ps1 "cmd" | -s | -k "key" | -r'
