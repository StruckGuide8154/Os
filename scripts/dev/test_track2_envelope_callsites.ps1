# ============================================================================
# Track 2 -- boot-chain / update-path envelope call-site test (QEMU)
#
# WHAT THIS PROVES (docs/track2-signed-everything-todo.md "host integration")
#   envelope_verify_signed is BOUND to the real call sites, in the real boot:
#   1. Normal boot: the build-emitted SYSSIG.ENV (threshold-Ed25519-signed
#      per-app integrity table) is verified at kmain K5 -> "[SYSSIG] ok c=1"
#      (the c=1 also proves the verified-artifact hash cache hit in-kernel),
#      and with no staged update "[UPDATE] none" is logged. Boot completes.
#   2. Tampered SYSSIG.ENV (one flipped signature byte): the kernel must
#      FAIL CLOSED -- "[SYSSIG] rc=" panic path, never "[SYSSIG] ok", never
#      [/BOOTTIME].
#   3. A quorum-signed KUPDATE.ENV staged on the ESP -> "[UPDATE] accepted".
#   4. The same KUPDATE.ENV with a flipped signature byte ->
#      "[UPDATE] rejected rc=" (and boot continues -- update input is
#      non-fatal, just inadmissible).
#   5. A dual-quorum-signed KQUORUM.ENV (policy-class envelope carrying a
#      QCH1 quorum-change payload, signed by BOTH the old and new quorum)
#      staged on the ESP -> "[QUORUM] accepted" (the change-tracking path
#      calling security_threshold_change_valid in the real boot).
#   6. The same KQUORUM.ENV with a flipped signature byte ->
#      "[QUORUM] rejected rc=" (non-fatal).
#   7. RTC/now binding: the kernel logs "[RTCNOW] now=" (the CMOS wallclock
#      bound into the verifier context at K5), and a KUPDATE.ENV whose
#      validity window EXPIRED in 2001 (--not-after 1000000000) is rejected
#      ("[UPDATE] rejected rc=E" = ENVR_ERR_WINDOW) despite valid quorum
#      signatures -- proving windows are judged against real time.
#   8. Persistent anti-rollback floors (floor_store.ghl): boot A admits a
#      validly signed v3 update ("[FLOOR] persisted g="); after a full
#      power cycle, boot B reloads the floors from the data.img floor
#      sector ("[FLOOR] loaded g=") and rejects a validly signed v2 update
#      of the same class ("[UPDATE] rejected rc=10" = ENVR_ERR_DOWNGRADE).
#   9. Loader-side KERNEL.BIN envelope (the last "no unsigned input"
#      residual): the build-emitted KERNEL.ENV (kernel-class envelope over
#      the SHA-256 of the KERNEL.BIN container) verifies against the
#      pristine loader-read image -> "[KERNSIG] ok n=" (asserted in phase 1);
#      a KERNEL.ENV whose signed digest does NOT match the image must FAIL
#      CLOSED ("[KERNSIG] rc=" panic, never "[KERNSIG] ok", no [/BOOTTIME]);
#      a MISSING KERNEL.ENV must also fail closed.
#
# The ESP is a live VVFAT directory (build\esp), so each phase swaps files on
# disk and reboots a fresh VM. SYSSIG.ENV is restored afterwards.
#
# USAGE
#   powershell scripts/dev/test_track2_envelope_callsites.ps1            # build first
#   powershell scripts/dev/test_track2_envelope_callsites.ps1 -SkipBuild
#
# EXIT 0 = all four phases behaved; non-zero = a call site regressed.
# ============================================================================
param(
    [switch]$SkipBuild,
    [int]$BootTimeoutSec = 60
)

$ErrorActionPreference = 'Stop'

$Root       = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$BuildDir   = Join-Path $Root 'build'
$Esp        = Join-Path $BuildDir 'esp\EFI\BOOT'
$SyssigPath = Join-Path $Esp 'SYSSIG.ENV'
$KupdPath   = Join-Path $Esp 'KUPDATE.ENV'
$KquorPath  = Join-Path $Esp 'KQUORUM.ENV'
$KernEnvPath = Join-Path $Esp 'KERNEL.ENV'
$SerialPort = 5555
$SerialLog  = Join-Path $BuildDir 'track2_callsites_serial.log'

function Reset-FloorSector {
    # Zero the persistent anti-rollback floor sector (floor_store.ghl
    # FLOOR_LBA = 2) of the QEMU IDE data disk so phase 8 starts from (and
    # the suite leaves behind) the build-time floors.
    $dataImg = Join-Path $BuildDir 'data.img'
    if (-not (Test-Path $dataImg)) { return }
    $fs = [System.IO.File]::Open($dataImg, 'Open', 'ReadWrite')
    try {
        $fs.Seek(2 * 512, 'Begin') | Out-Null
        $fs.Write((New-Object byte[] 512), 0, 512)
    } finally { $fs.Close() }
}

function Stop-QemuIfRunning {
    Get-Process qemu-system-x86_64 -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 400
}

function Boot-AndCapture([string[]]$StopMarkers, [int]$TimeoutSec) {
    # Boot headless via the canonical harness; capture serial until any stop
    # marker (or timeout) and return the captured text.
    Stop-QemuIfRunning
    $job = Start-Job -ScriptBlock {
        param($RootPath)
        powershell -ExecutionPolicy Bypass -File (Join-Path $RootPath 'scripts\run\run_uefi.ps1') -Headless -NoPassthrough -SerialTcp
    } -ArgumentList "$Root"
    try {
        $client = $null
        $deadline = [DateTime]::UtcNow.AddSeconds(15)
        while ([DateTime]::UtcNow -lt $deadline -and -not $client) {
            try {
                $client = [System.Net.Sockets.TcpClient]::new()
                $client.Connect('127.0.0.1', $SerialPort)
            } catch { $client = $null; Start-Sleep -Milliseconds 300 }
        }
        if (-not $client) { throw 'Could not connect to QEMU serial on 5555' }
        $stream = $client.GetStream()
        $buf = New-Object byte[] 65536
        $sb  = New-Object System.Text.StringBuilder
        $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
        while ([DateTime]::UtcNow -lt $deadline) {
            if ($stream.DataAvailable) {
                $n = $stream.Read($buf, 0, $buf.Length)
                if ($n -gt 0) {
                    [void]$sb.Append([System.Text.Encoding]::ASCII.GetString($buf, 0, $n))
                    $txt = $sb.ToString()
                    $hit = $false
                    foreach ($m in $StopMarkers) { if ($txt.Contains($m)) { $hit = $true } }
                    if ($hit) { Start-Sleep -Milliseconds 500; break }
                }
            } else { Start-Sleep -Milliseconds 50 }
        }
        $client.Close()
        return $sb.ToString()
    } finally {
        Stop-QemuIfRunning
        Remove-Job $job -Force -ErrorAction SilentlyContinue
    }
}

$fails = [System.Collections.Generic.List[string]]::new()
function Check([string]$Label, [bool]$Ok) {
    $tag = if ($Ok) { 'ok' } else { 'FAIL' }
    $color = if ($Ok) { 'Green' } else { 'Red' }
    Write-Host ("[track2-callsites] {0,-58} [{1}]" -f $Label, $tag) -ForegroundColor $color
    if (-not $Ok) { $fails.Add($Label) }
}

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ' Track 2 -- envelope_verify_signed call-site binding (QEMU)' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan

$syssigBackup = $null
$kernEnvBackup = $null
try {
    if (-not $SkipBuild) {
        Write-Host '[track2-callsites] Building UEFI image...' -ForegroundColor Yellow
        powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $Root 'scripts\build\build_uefi.ps1') | Out-Host
        if ($LASTEXITCODE -ne 0) { throw 'build_uefi.ps1 failed' }
    }
    if (-not (Test-Path $SyssigPath)) { throw "SYSSIG.ENV missing from ESP ($SyssigPath) -- build first" }
    if (Test-Path $SerialLog) { Remove-Item $SerialLog -Force }
    if (Test-Path $KupdPath)  { Remove-Item $KupdPath -Force }
    $syssigBackup = [System.IO.File]::ReadAllBytes($SyssigPath)

    # ---- Phase 1: normal boot --------------------------------------------
    Write-Host '[track2-callsites] Phase 1: normal boot (signed SYSSIG, no update)...' -ForegroundColor Yellow
    $log = Boot-AndCapture @('[/BOOTTIME]') $BootTimeoutSec
    Add-Content $SerialLog "===== PHASE 1 =====`n$log"
    Check 'signed SYSSIG accepted ("[SYSSIG] ok")' ($log.Contains('[SYSSIG] ok'))
    Check 'in-kernel hash-cache hit on re-admit (c=...1)' ($log -match '\[SYSSIG\] ok c=0*1\b')
    Check 'no staged update -> "[UPDATE] none"' ($log.Contains('[UPDATE] none'))
    Check 'no staged quorum change -> "[QUORUM] none"' ($log.Contains('[QUORUM] none'))
    Check 'RTC wallclock bound into the gate ("[RTCNOW] now=")' ($log.Contains('[RTCNOW] now='))
    Check 'KERNEL.BIN envelope verified ("[KERNSIG] ok n=")' ($log.Contains('[KERNSIG] ok n='))
    Check 'boot completes ([/BOOTTIME])' ($log.Contains('[/BOOTTIME]'))

    # ---- Phase 2: tampered SYSSIG must fail closed ------------------------
    Write-Host '[track2-callsites] Phase 2: tampered SYSSIG.ENV (flip last sig byte)...' -ForegroundColor Yellow
    $bad = [byte[]]$syssigBackup.Clone()
    $bad[$bad.Length - 1] = $bad[$bad.Length - 1] -bxor 0x80
    [System.IO.File]::WriteAllBytes($SyssigPath, $bad)
    $log = Boot-AndCapture @('[SYSSIG] rc=', '[/BOOTTIME]') $BootTimeoutSec
    Add-Content $SerialLog "===== PHASE 2 =====`n$log"
    Check 'tampered SYSSIG rejected ("[SYSSIG] rc=")' ($log.Contains('[SYSSIG] rc='))
    Check 'tampered SYSSIG never accepted' (-not $log.Contains('[SYSSIG] ok'))
    Check 'boot does NOT complete (fail closed)' (-not $log.Contains('[/BOOTTIME]'))
    [System.IO.File]::WriteAllBytes($SyssigPath, $syssigBackup)

    # ---- Phase 3: signed staged update accepted ----------------------------
    Write-Host '[track2-callsites] Phase 3: quorum-signed KUPDATE.ENV staged...' -ForegroundColor Yellow
    $updPayload = Join-Path $BuildDir 'track2_test_update_payload.bin'
    [System.IO.File]::WriteAllBytes($updPayload, [System.Text.Encoding]::ASCII.GetBytes('Grit staged update test artifact'))
    & python (Join-Path $Root 'scripts\build\write_envelope.py') `
        --payload $updPayload --out $KupdPath --type update --device-id 1 | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'write_envelope.py failed for KUPDATE.ENV' }
    $log = Boot-AndCapture @('[/BOOTTIME]') $BootTimeoutSec
    Add-Content $SerialLog "===== PHASE 3 =====`n$log"
    Check 'signed staged update accepted ("[UPDATE] accepted")' ($log.Contains('[UPDATE] accepted'))
    Check 'boot completes with staged update' ($log.Contains('[/BOOTTIME]'))

    # ---- Phase 4: tampered staged update rejected, boot continues ----------
    Write-Host '[track2-callsites] Phase 4: tampered KUPDATE.ENV...' -ForegroundColor Yellow
    $upd = [System.IO.File]::ReadAllBytes($KupdPath)
    $upd[$upd.Length - 1] = $upd[$upd.Length - 1] -bxor 0x80
    [System.IO.File]::WriteAllBytes($KupdPath, $upd)
    $log = Boot-AndCapture @('[/BOOTTIME]') $BootTimeoutSec
    Add-Content $SerialLog "===== PHASE 4 =====`n$log"
    Check 'tampered update rejected ("[UPDATE] rejected rc=")' ($log.Contains('[UPDATE] rejected rc='))
    Check 'tampered update never accepted' (-not $log.Contains('[UPDATE] accepted'))
    Check 'update rejection is non-fatal (boot completes)' ($log.Contains('[/BOOTTIME]'))
    if (Test-Path $KupdPath) { Remove-Item $KupdPath -Force }

    # ---- Phase 5: dual-quorum-signed quorum change accepted -----------------
    Write-Host '[track2-callsites] Phase 5: dual-quorum-signed KQUORUM.ENV staged...' -ForegroundColor Yellow
    # QCH1 payload: raise the CONFIG class (kind 7) quorum 2-of -> 3-of.
    # old rule (2, 0x3F, 0x04) is the build-time active rule; signing roles
    # 1,2,3 satisfy both the old quorum (>=2 incl POLICY) and the new (>=3).
    $qchPayload = Join-Path $BuildDir 'track2_test_quorum_change.bin'
    $qch = [System.Text.Encoding]::ASCII.GetBytes('QCH1') + [byte[]]@(
        7,0,  2,0, 0x3F,0, 4,0,  3,0, 0x3F,0, 4,0)
    [System.IO.File]::WriteAllBytes($qchPayload, $qch)
    & python (Join-Path $Root 'scripts\build\write_envelope.py') `
        --payload $qchPayload --out $KquorPath --type policy --device-id 1 `
        --sign-roles 1,2,3 | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'write_envelope.py failed for KQUORUM.ENV' }
    $log = Boot-AndCapture @('[/BOOTTIME]') $BootTimeoutSec
    Add-Content $SerialLog "===== PHASE 5 =====`n$log"
    Check 'dual-quorum change accepted ("[QUORUM] accepted")' ($log.Contains('[QUORUM] accepted'))
    Check 'boot completes with accepted quorum change' ($log.Contains('[/BOOTTIME]'))

    # ---- Phase 6: tampered quorum change rejected, boot continues -----------
    Write-Host '[track2-callsites] Phase 6: tampered KQUORUM.ENV...' -ForegroundColor Yellow
    $qenv = [System.IO.File]::ReadAllBytes($KquorPath)
    $qenv[$qenv.Length - 1] = $qenv[$qenv.Length - 1] -bxor 0x80
    [System.IO.File]::WriteAllBytes($KquorPath, $qenv)
    $log = Boot-AndCapture @('[/BOOTTIME]') $BootTimeoutSec
    Add-Content $SerialLog "===== PHASE 6 =====`n$log"
    Check 'tampered quorum change rejected ("[QUORUM] rejected rc=")' ($log.Contains('[QUORUM] rejected rc='))
    Check 'tampered quorum change never accepted' (-not $log.Contains('[QUORUM] accepted'))
    Check 'quorum-change rejection is non-fatal (boot completes)' ($log.Contains('[/BOOTTIME]'))
    if (Test-Path $KquorPath) { Remove-Item $KquorPath -Force }

    # ---- Phase 7: EXPIRED (validly signed) update rejected vs the live RTC --
    Write-Host '[track2-callsites] Phase 7: expired KUPDATE.ENV (window ended 2001)...' -ForegroundColor Yellow
    & python (Join-Path $Root 'scripts\build\write_envelope.py') `
        --payload $updPayload --out $KupdPath --type update --device-id 1 `
        --not-after 1000000000 | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'write_envelope.py failed for expired KUPDATE.ENV' }
    $log = Boot-AndCapture @('[/BOOTTIME]') $BootTimeoutSec
    Add-Content $SerialLog "===== PHASE 7 =====`n$log"
    # ENVR_ERR_WINDOW = 14 = 0xE (ser_print_hex64 prints hex).
    Check 'expired update rejected vs live clock (rc=...E)' ($log -match '\[UPDATE\] rejected rc=0*E\b')
    Check 'expired update never accepted' (-not $log.Contains('[UPDATE] accepted'))
    Check 'window rejection is non-fatal (boot completes)' ($log.Contains('[/BOOTTIME]'))
    if (Test-Path $KupdPath) { Remove-Item $KupdPath -Force }

    # ---- Phase 8: persistent anti-rollback floors survive a reboot ----------
    # Boot A admits a validly signed v3 update; floor_store persists the raised
    # class floor to the data.img floor sector (LBA 2). Boot B then stages a
    # validly signed v2 update of the SAME class: the reloaded floor must make
    # it inadmissible (ENVR_ERR_DOWNGRADE = 16 = 0x10) across the power cycle.
    Write-Host '[track2-callsites] Phase 8: floor persistence across reboot (v3 then v2)...' -ForegroundColor Yellow
    Reset-FloorSector
    & python (Join-Path $Root 'scripts\build\write_envelope.py') `
        --payload $updPayload --out $KupdPath --type update --device-id 1 `
        --version 3 | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'write_envelope.py failed for v3 KUPDATE.ENV' }
    $log = Boot-AndCapture @('[/BOOTTIME]') $BootTimeoutSec
    Add-Content $SerialLog "===== PHASE 8A =====`n$log"
    Check 'v3 update accepted (boot A)' ($log.Contains('[UPDATE] accepted'))
    Check 'raised floor persisted to disk ("[FLOOR] persisted g=")' ($log.Contains('[FLOOR] persisted g='))
    & python (Join-Path $Root 'scripts\build\write_envelope.py') `
        --payload $updPayload --out $KupdPath --type update --device-id 1 `
        --version 2 | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'write_envelope.py failed for v2 KUPDATE.ENV' }
    $log = Boot-AndCapture @('[/BOOTTIME]') $BootTimeoutSec
    Add-Content $SerialLog "===== PHASE 8B =====`n$log"
    Check 'persisted floors reload on boot B ("[FLOOR] loaded g=")' ($log.Contains('[FLOOR] loaded g='))
    Check 'superseded v2 update rejected across reboot (rc=...10 DOWNGRADE)' ($log -match '\[UPDATE\] rejected rc=0*10\b')
    Check 'superseded update never accepted' (-not $log.Contains('[UPDATE] accepted'))
    Check 'rollback rejection is non-fatal (boot completes)' ($log.Contains('[/BOOTTIME]'))
    if (Test-Path $KupdPath) { Remove-Item $KupdPath -Force }

    # ---- Phase 9: loader-side KERNEL.BIN envelope fails closed --------------
    Write-Host '[track2-callsites] Phase 9: KERNEL.ENV digest mismatch + missing file...' -ForegroundColor Yellow
    $kernEnvBackup = [System.IO.File]::ReadAllBytes($KernEnvPath)
    # A validly signed kernel-class envelope over the WRONG digest: sign 32
    # bytes that are not the image hash. Crypto passes; the payload-vs-image
    # compare must panic ('KSG3').
    $wrongDigest = Join-Path $BuildDir 'track2_test_wrong_kdigest.bin'
    [System.IO.File]::WriteAllBytes($wrongDigest, (New-Object byte[] 32))
    & python (Join-Path $Root 'scripts\build\write_envelope.py') `
        --payload $wrongDigest --out $KernEnvPath --type kernel --device-id 1 | Out-Host
    if ($LASTEXITCODE -ne 0) { throw 'write_envelope.py failed for wrong-digest KERNEL.ENV' }
    $log = Boot-AndCapture @('[KERNSIG] rc=', '[/BOOTTIME]') $BootTimeoutSec
    Add-Content $SerialLog "===== PHASE 9A =====`n$log"
    Check 'wrong-digest KERNEL.ENV fails closed ("[KERNSIG] rc=")' ($log.Contains('[KERNSIG] rc='))
    Check 'wrong-digest KERNEL.ENV never accepted' (-not $log.Contains('[KERNSIG] ok'))
    Check 'boot does NOT complete on kernel-envelope mismatch' (-not $log.Contains('[/BOOTTIME]'))
    Remove-Item $KernEnvPath -Force
    $log = Boot-AndCapture @('[KERNSIG] rc=', '[/BOOTTIME]') $BootTimeoutSec
    Add-Content $SerialLog "===== PHASE 9B =====`n$log"
    Check 'missing KERNEL.ENV fails closed ("[KERNSIG] rc=")' ($log.Contains('[KERNSIG] rc='))
    Check 'boot does NOT complete without KERNEL.ENV' (-not $log.Contains('[/BOOTTIME]'))
    [System.IO.File]::WriteAllBytes($KernEnvPath, $kernEnvBackup)
} finally {
    if ($syssigBackup) { [System.IO.File]::WriteAllBytes($SyssigPath, $syssigBackup) }
    if ($kernEnvBackup) { [System.IO.File]::WriteAllBytes($KernEnvPath, $kernEnvBackup) }
    if (Test-Path $KupdPath) { Remove-Item $KupdPath -Force }
    if (Test-Path $KquorPath) { Remove-Item $KquorPath -Force }
    Reset-FloorSector
    Stop-QemuIfRunning
}

Write-Host ''
if ($fails.Count -gt 0) {
    Write-Host "[track2-callsites] FAIL -- $($fails.Count) problem(s):" -ForegroundColor Red
    $fails | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    Write-Host "  serial log: $SerialLog" -ForegroundColor DarkGray
    exit 1
}
Write-Host '[track2-callsites] PASS -- envelope_verify_signed is bound to the boot-chain and update-path call sites; unsigned/tampered input is inadmissible.' -ForegroundColor Green
exit 0
