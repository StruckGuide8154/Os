# Repro: open Settings (start-menu row index 3, y=1002) and verify the window
# stays alive + draws instead of being struck-killed at the CAP_CORE launch gap.
param([int]$BootWaitMs = 16000)
$ErrorActionPreference = 'Continue'
$Root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$Serial = Join-Path $Root 'build\serial_full.log'

function Send-Monitor([string[]]$cmds,[int]$ms=300){ $c=[Net.Sockets.TcpClient]::new();$c.Connect('127.0.0.1',4444);$s=$c.GetStream();foreach($cmd in $cmds){$b=[Text.Encoding]::ASCII.GetBytes("$cmd`r`n");$s.Write($b,0,$b.Length);$s.Flush();Start-Sleep -Milliseconds $ms};$c.Close() }
function Move-To([int]$tx,[int]$ty){ $a=1.5;$rx=[int]($tx/$a);$ry=[int]($ty/$a);$c=@();1..16|%{$c+='mouse_move -200 -200'};Send-Monitor $c 25;$x=0;$y=0;$st=@();while($x -lt $rx -or $y -lt $ry){$dx=[Math]::Min(20,$rx-$x);$dy=[Math]::Min(20,$ry-$y);if($dx -lt 0){$dx=0};if($dy -lt 0){$dy=0};$st+="mouse_move $dx $dy";$x+=$dx;$y+=$dy};Send-Monitor $st 25 }
function Click(){ Send-Monitor @('mouse_button 1') 120;Send-Monitor @('mouse_button 0') 250 }

Get-Process qemu-system-x86_64 -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Milliseconds 600
Remove-Item $Serial -Force -ErrorAction SilentlyContinue
$job = Start-Job -ScriptBlock { powershell -ExecutionPolicy Bypass -File "C:\Users\user\Documents\new\scripts\run\run_uefi.ps1" -Headless -NoPassthrough }
Start-Sleep -Milliseconds $BootWaitMs

$mark=(Get-Content $Serial -ErrorAction SilentlyContinue).Count
Move-To 39 1182; Click            # Start menu
Move-To 104 1002; Click           # Settings row (index 3)
Start-Sleep -Milliseconds 4000    # let several render frames pass (gap + recovery + would-be strike-kill window)
$dump = (Join-Path $Root 'build\settings_after.ppm') -replace '\\','/'
Send-Monitor @("screendump $dump") 1200

Write-Host "==== XMAN (launch mask applied) ===="
(Select-String -Path $Serial -Pattern 'XMAN' -ErrorAction SilentlyContinue | Select-Object -Last 6 | % { ($_.Line -split 'XMAN')[-1].Trim() })
Write-Host "==== XCAP count (cap rejects) ===="
(Select-String -Path $Serial -Pattern 'XCAP' -SimpleMatch -ErrorAction SilentlyContinue | Measure-Object).Count
Write-Host "==== strike-kill / teardown markers (expect none) ===="
$m = Select-String -Path $Serial -Pattern 'CAPT|R3CN|CANARY|TXBF' -SimpleMatch -ErrorAction SilentlyContinue
if ($m) { $m | % { $_.Line } } else { Write-Host '(none)' }

Send-Monitor @('quit') 200
Get-Process qemu-system-x86_64 -ErrorAction SilentlyContinue | Stop-Process -Force
Stop-Job $job -ErrorAction SilentlyContinue|Out-Null; Remove-Job $job -Force -ErrorAction SilentlyContinue|Out-Null
