# Boot, open Task Manager, leave the (frozen) VM alive and dump monitor diagnostics
# around the faulting ring-3 RIP so we can see how ring-3 reached the resident blob.
param([int]$BootWaitMs = 16000)
$ErrorActionPreference = 'Continue'
$Root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$Serial = Join-Path $Root 'build\serial_full.log'

function Mon([string[]]$cmds, [int]$settleMs = 250) {
    $c = [System.Net.Sockets.TcpClient]::new(); $c.Connect('127.0.0.1', 4444)
    $s = $c.GetStream(); $buf = New-Object byte[] 65536; $sb = [System.Text.StringBuilder]::new()
    Start-Sleep -Milliseconds 150
    foreach ($cmd in $cmds) {
        $b = [System.Text.Encoding]::ASCII.GetBytes("$cmd`r`n")
        $s.Write($b, 0, $b.Length); $s.Flush(); Start-Sleep -Milliseconds $settleMs
        while ($s.DataAvailable) { $n = $s.Read($buf,0,$buf.Length); [void]$sb.Append([Text.Encoding]::ASCII.GetString($buf,0,$n)) }
    }
    $c.Close()
    ($sb.ToString() -replace '\x1b\[[0-9;]*[A-Za-z]','')
}
function Move-To([int]$tx,[int]$ty){ $a=1.5;$rx=[int]($tx/$a);$ry=[int]($ty/$a);$c=@();1..16|%{$c+='mouse_move -200 -200'};Mon $c 25|Out-Null;$x=0;$y=0;$st=@();while($x -lt $rx -or $y -lt $ry){$dx=[Math]::Min(20,$rx-$x);$dy=[Math]::Min(20,$ry-$y);if($dx -lt 0){$dx=0};if($dy -lt 0){$dy=0};$st+="mouse_move $dx $dy";$x+=$dx;$y+=$dy};Mon $st 25|Out-Null }
function Click(){ Mon @('mouse_button 1') 120|Out-Null; Mon @('mouse_button 0') 200|Out-Null }

Get-Process qemu-system-x86_64 -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 500
if (Test-Path $Serial) { Remove-Item $Serial -Force -ErrorAction SilentlyContinue }
$job = Start-Job -ScriptBlock { param($R) powershell -ExecutionPolicy Bypass -File (Join-Path $R 'scripts\run\run_uefi.ps1') -Headless -NoPassthrough } -ArgumentList $Root
Start-Sleep -Milliseconds $BootWaitMs

Move-To 39 1182; Click                  # Start menu
Move-To 104 1058; Click                 # Task Manager row
Start-Sleep -Milliseconds 1500

# Pull the faulting RIP / user RSP out of the serial exception dump.
$rip = '0x145C87'; $ursp = '0xBFFEA8'
$x = Select-String -Path $Serial -Pattern 'X0000000000000(00E|00E)@([0-9A-F]+)#' -ErrorAction SilentlyContinue | Select-Object -Last 1
Write-Host "=== info registers (CPU0) ==="
Mon @('info registers')
Write-Host "=== disas faulting RIP region ==="
Mon @("x /6i $rip")
Write-Host "=== user stack (return chain) @ $ursp ==="
Mon @("x /16gx $ursp")
Write-Host "=== translate faulting RIP page ==="
Mon @("info tlb")  | Select-String -Pattern '0000000000145' | ForEach-Object { $_.Line }
Write-Host "=== bytes at 0x145000..0x146000 (gva) ==="
Mon @("x /8i 0x145000")

Mon @('quit') 200 | Out-Null
Get-Process qemu-system-x86_64 -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Stop-Job $job -ErrorAction SilentlyContinue | Out-Null; Remove-Job $job -Force -ErrorAction SilentlyContinue | Out-Null
