# ============================================================================
# Track 4 Verification - QEMU pmemsave RAM-dump grep test
#
# WHAT THIS PROVES
#   docs/track4-ram-secure-erasure-todo.md "Verification" items:
#   - RAM-dump test: dump guest RAM via QEMU monitor pmemsave and grep for
#     known plaintext sentinels that must NOT appear after the volatile wipe.
#   - Negative test: a sentinel planted in a data region must vanish after
#     nx_volatile_wipe_halt runs (the 'w' serial command).
#   - Amnesia test proxy: the wipe runs, pmemsave captures the post-wipe DRAM
#     image, and the sentinel is absent.
#
# PROTOCOL
#   Phase 1 - Pre-wipe baseline dump:
#     Boot headless, wait for [/BOOTTIME] (OS fully up, secrets drawn). Send
#     QEMU monitor "pmemsave 0 0x20000000 <file>" (512 MiB). Grep the dump for
#     the known test sentinels. Record which are found (expected: some will be
#     present in the live image - these are the documented live-working-set
#     residuals).
#
#   Phase 2 - Post-wipe dump:
#     Send serial 'w' command to trigger nx_volatile_wipe_halt(). Wait for
#     [WIPED] marker on serial (confirms scrub completed). Send pmemsave again.
#     Grep for the SAME sentinels. Secrets that were scrubbed by
#     nx_volatile_scrub_secrets MUST NOT appear. The irreducible residual
#     (.text, page tables, QEMU firmware) may still appear and is documented.
#
# SENTINELS (what we search for in the RAM dump)
#
#   The test defines two classes of sentinel:
#
#   MUST-VANISH sentinels - values that nx_volatile_scrub_secrets zeroes:
#     These are the per-boot secrets named in the scrub function. We cannot
#     know their run-time values in advance (they are random), so instead we
#     search for the ASCII debug tokens that the serial log records - if the
#     serial log contains a [CANARY:0x...] print, that hex value is our
#     sentinel. If those tokens are not present (non-debug build), we use
#     the static strings that nx_mem_key initialization fallback writes
#     ("MEMKEY01") as a canary sentinel.
#
#   STATIC-STRING sentinels that must NEVER appear in plaintext (data hygiene):
#     These are cleartext secrets that should never be in plaintext in DRAM,
#     e.g. well-known test passwords or private keys. For Grit the only
#     embedded literal that would be a real secret is the QRNG seed, which is
#     compiled in - but its presence is the documented residual (it is in the
#     read-only .text, always visible), so we do NOT check for its absence.
#     Instead we check that after the wipe the per-boot secret region does not
#     contain the fallback guard value "MEMKEY01" (which would mean the memory
#     key draw produced the fallback constant - a weak-entropy signal).
#
#   DOCUMENTED RESIDUALS (found pre-wipe AND post-wipe - expected, not a fail):
#     - The kernel .text / UEFI firmware bytes (always present, irreducible)
#     - The QEMU OVMF firmware strings (e.g. "BdsDxe")
#     These are logged but not asserted absent.
#
# HONEST SCOPE CAVEAT (mandatory per track doc)
#   QEMU TCG does NOT emulate Intel TME or AMD SME hardware memory-controller
#   encryption. Under TCG, guest DRAM is plaintext on the host regardless of
#   FME status. This test therefore validates ONLY the SOFTWARE scrub layer
#   (nx_volatile_scrub_secrets / nx_volatile_wipe_arenas). Part C (TME/SME)
#   verification requires real silicon or KVM+SEV - that is out of scope here
#   and is documented as such in docs/track4-ram-secure-erasure-todo.md Part C.
#
# USAGE
#   pwsh scripts/dev/test_track4_pmemsave.ps1
#   pwsh scripts/dev/test_track4_pmemsave.ps1 -SkipBuild
#   pwsh scripts/dev/test_track4_pmemsave.ps1 -SkipBuild -GuestMemMB 256
#
# EXIT 0 = post-wipe dump contains no must-vanish secrets.
# Non-zero = scrub regression or boot failure.
# ============================================================================
param(
    [switch]$SkipBuild,
    [int]$BootTimeoutSec   = 50,
    [int]$WipeTimeoutSec   = 15,
    [int]$GuestMemMB       = 512
)

$ErrorActionPreference = 'Stop'

$Root       = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$BuildDir   = Join-Path $Root 'build'
$QEMU       = 'C:\Program Files\qemu\qemu-system-x86_64.exe'
$MonPort    = 4444
$SerialPort = 5555
$SerialHost = '127.0.0.1'
$DumpPre    = Join-Path $BuildDir 'track4_pmemsave_pre.bin'
$DumpPost   = Join-Path $BuildDir 'track4_pmemsave_post.bin'
$SerialLog  = Join-Path $BuildDir 'track4_pmemsave_serial.log'
$DumpSizeMB = [Math]::Min($GuestMemMB, 512)
$DumpSizeHex = '0x{0:X}' -f ($DumpSizeMB * 1024 * 1024)

# The nx_mem_key fallback guard ("MEMKEY01") written when RDRAND is absent
# and entropy is weakest. Its presence in a SCRUBBED dump would indicate the
# scrub did not zero the mem-key region. As ASCII bytes:
#   M=0x4D E=0x45 M=0x4D K=0x4B E=0x45 Y=0x59 0=0x30 1=0x31
$SentinelMemkey01 = [byte[]]@(0x4D,0x45,0x4D,0x4B,0x45,0x59,0x30,0x31)

# Sentinel: the ASCII string "GRIT_TRACK4_SENTINEL" assembled at runtime in
# nx_track4_pmemsave_sentinel. It is deliberately absent from the read-only
# kernel image, MUST be present in the live pre-wipe dump, and MUST disappear
# after nx_volatile_scrub_secrets zeroes that writable region.
$SentinelString = 'GRIT_TRACK4_SENTINEL'
$SentinelBytes  = [System.Text.Encoding]::ASCII.GetBytes($SentinelString)

# ============================================================================
function Stop-QemuIfRunning {
    try {
        $c = [System.Net.Sockets.TcpClient]::new()
        $c.Connect('127.0.0.1', $MonPort)
        $s = $c.GetStream()
        $b = [System.Text.Encoding]::ASCII.GetBytes("quit`r`n")
        $s.Write($b, 0, $b.Length); $s.Flush(); $c.Close()
        Start-Sleep -Milliseconds 600
    } catch {}
    Get-Process qemu-system-x86_64 -ErrorAction SilentlyContinue |
        Stop-Process -Force -ErrorAction SilentlyContinue
}

function Send-MonitorCmd([string]$Cmd, [int]$WaitMs = 400) {
    $c = [System.Net.Sockets.TcpClient]::new()
    $c.Connect('127.0.0.1', $MonPort)
    $s = $c.GetStream()
    $b = [System.Text.Encoding]::ASCII.GetBytes("$Cmd`r`n")
    $s.Write($b, 0, $b.Length); $s.Flush()
    Start-Sleep -Milliseconds $WaitMs
    $c.Close()
}

function Connect-Serial {
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $c = [System.Net.Sockets.TcpClient]::new()
            $c.Connect($SerialHost, $SerialPort)
            return $c
        } catch {
            Start-Sleep -Milliseconds 200
        }
    }
    throw "Could not connect to serial on $SerialHost`:$SerialPort"
}

# One persistent serial connection for the whole session: QEMU's TCP serial
# drops output emitted while no client is attached, so reconnect-per-operation
# would race the [WIPED] marker.
function Send-SerialByte([System.Net.Sockets.TcpClient]$Client, [byte]$b) {
    try {
        $s = $Client.GetStream()
        $s.Write([byte[]]@($b), 0, 1); $s.Flush()
        Start-Sleep -Milliseconds 200
    } catch {
        Write-Host "  [warn] serial send failed: $_" -ForegroundColor DarkYellow
    }
}

function Read-SerialUntilMarker([System.Net.Sockets.TcpClient]$Client, [string]$Marker, [int]$TimeoutSec) {
    $stream  = $Client.GetStream()
    $buf     = New-Object byte[] 65536
    $sb      = New-Object System.Text.StringBuilder
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSec)
    while ([DateTime]::UtcNow -lt $deadline) {
        if ($stream.DataAvailable) {
            $n = $stream.Read($buf, 0, $buf.Length)
            if ($n -gt 0) {
                $chunk = [System.Text.Encoding]::ASCII.GetString($buf, 0, $n)
                [void]$sb.Append($chunk)
                # literal match: markers contain [ ] which -like treats as a char class
                if ($sb.ToString().Contains($Marker)) { break }
            }
        } else { Start-Sleep -Milliseconds 50 }
    }
    return $sb.ToString()
}

function Search-BytePattern([byte[]]$haystack, [byte[]]$needle) {
    if ($needle.Length -eq 0 -or $haystack.Length -lt $needle.Length) { return @() }
    # Latin-1 (28591) maps bytes 1:1 to chars, so String.IndexOf(Ordinal) is a
    # byte-exact search; a naive nested byte loop takes hours on a 512 MiB dump.
    $enc = [System.Text.Encoding]::GetEncoding(28591)
    $hay = $enc.GetString($haystack)
    $nee = $enc.GetString($needle)
    $found = [System.Collections.Generic.List[int]]::new()
    $i = $hay.IndexOf($nee, [System.StringComparison]::Ordinal)
    while ($i -ge 0) {
        $found.Add($i)
        $i = $hay.IndexOf($nee, $i + 1, [System.StringComparison]::Ordinal)
    }
    return $found.ToArray()
}

function Extract-SerialToken([string]$log, [string]$prefix) {
    if ($log -match "$prefix`:?(0x[0-9A-Fa-f]+|\d+)") { return $Matches[1] }
    return $null
}

# ============================================================================
$overall = $true
$fails   = [System.Collections.Generic.List[string]]::new()

Write-Host ''
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ' Track 4 - QEMU pmemsave RAM-dump grep test' -ForegroundColor Cyan
Write-Host ' Validating: software scrub removes secrets from DRAM' -ForegroundColor Cyan
Write-Host '============================================================' -ForegroundColor Cyan
Write-Host ''
Write-Host '[SCOPE] QEMU TCG does NOT emulate Intel TME/AMD SME.' -ForegroundColor DarkYellow
Write-Host '        This test validates the SOFTWARE scrub layer only.' -ForegroundColor DarkYellow
Write-Host '        Part C (hardware FME) requires real silicon or KVM+SEV.' -ForegroundColor DarkYellow
Write-Host '        See docs/track4-ram-secure-erasure-todo.md Part C.' -ForegroundColor DarkYellow
Write-Host ''

try {
    Stop-QemuIfRunning
    $null = New-Item -ItemType Directory -Path $BuildDir -Force
    if (Test-Path $SerialLog) { Remove-Item $SerialLog -Force }

    # ------------------------------------------------------------------
    # Build
    # ------------------------------------------------------------------
    if (-not $SkipBuild) {
        Write-Host '[track4-pmemsave] Building UEFI image...' -ForegroundColor Yellow
        $buildOut = powershell -NoProfile -ExecutionPolicy Bypass `
            -File (Join-Path $Root 'scripts\build\build_uefi.ps1') 2>&1
        $buildOut | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "build_uefi.ps1 failed (exit $LASTEXITCODE)" }
        Write-Host '[track4-pmemsave] Build OK.' -ForegroundColor Green
    } else {
        Write-Host '[track4-pmemsave] -SkipBuild: reusing existing build.' -ForegroundColor DarkGray
    }

    # The positive-control sentinel must not be embedded as a contiguous string
    # in the immutable image, or its post-wipe residual would be ambiguous.
    $BinPath = Join-Path $BuildDir 'esp\EFI\BOOT\KERNEL.BIN'
    if (-not (Test-Path $BinPath)) { throw "Kernel binary not found at $BinPath" }
    $binBytes = [System.IO.File]::ReadAllBytes($BinPath)
    $sentinelInBin = (Search-BytePattern $binBytes $SentinelBytes).Count -gt 0
    if ($sentinelInBin) {
        throw "Positive-control sentinel '$SentinelString' is embedded in KERNEL.BIN; it must be constructed only in writable runtime RAM."
    } else {
        Write-Host "[track4-pmemsave] Positive-control sentinel is absent from immutable KERNEL.BIN (expected)." -ForegroundColor Green
    }

    # ------------------------------------------------------------------
    # Boot VM (serial TCP + QEMU monitor)
    # ------------------------------------------------------------------
    # Boot through the canonical harness (same path test_smoke_uefi.ps1 uses):
    # run_uefi.ps1 -SerialTcp serves serial on TCP 5555 and always exposes the
    # QEMU monitor on telnet 4444.
    Write-Host '[track4-pmemsave] Booting VM headless via run_uefi.ps1 (serial TCP + monitor)...' -ForegroundColor Yellow
    $bootJob = Start-Job -ScriptBlock {
        param($RootPath, $MemMB)
        powershell -ExecutionPolicy Bypass -File (Join-Path $RootPath 'scripts\run\run_uefi.ps1') -Headless -NoPassthrough -SerialTcp -GuestMemory "${MemMB}M"
    } -ArgumentList "$Root", $GuestMemMB

    $serialClient = Connect-Serial

    # Wait for [/BOOTTIME]
    Write-Host '[track4-pmemsave] Waiting for [/BOOTTIME]...' -ForegroundColor Yellow
    $bootLog = Read-SerialUntilMarker $serialClient '[/BOOTTIME]' $BootTimeoutSec
    Add-Content -Path $SerialLog -Value $bootLog

    if (-not $bootLog.Contains('[/BOOTTIME]')) {
        throw "Boot did not reach [/BOOTTIME] within ${BootTimeoutSec}s. Serial captured:`n$bootLog"
    }
    Write-Host '[track4-pmemsave] [/BOOTTIME] reached - OS up, secrets drawn.' -ForegroundColor Green

    # Extract per-boot secret token (optional - present in debug builds)
    $canaryToken = Extract-SerialToken $bootLog 'CANARY'
    $nonceToken  = Extract-SerialToken $bootLog 'NONCE'
    if ($canaryToken) { Write-Host "  CANARY token from serial: $canaryToken" -ForegroundColor Gray }
    if ($nonceToken)  { Write-Host "  NONCE  token from serial: $nonceToken"  -ForegroundColor Gray }

    # Give the OS a moment to settle after boot animation
    Start-Sleep -Seconds 3

    # ------------------------------------------------------------------
    # Phase 1 - Pre-wipe RAM dump
    # ------------------------------------------------------------------
    Write-Host ''
    Write-Host "--- Phase 1: Pre-wipe pmemsave (${DumpSizeMB} MiB -> $DumpPre) ---" -ForegroundColor Cyan
    Write-Host '    (This is the live-running image - some secrets WILL be present)' -ForegroundColor DarkGray

    if (Test-Path $DumpPre) { Remove-Item $DumpPre -Force }
    # pmemsave is slow for large images; give it extra time. The monitor
    # treats backslashes as escapes, so the path must use forward slashes.
    Send-MonitorCmd "pmemsave 0 $DumpSizeHex `"$($DumpPre -replace '\\','/')`"" -WaitMs (15 * 1000)

    $preDumpSecs = 20
    $preDumpDeadline = [DateTime]::UtcNow.AddSeconds($preDumpSecs)
    while (-not (Test-Path $DumpPre) -and [DateTime]::UtcNow -lt $preDumpDeadline) {
        Start-Sleep -Milliseconds 500
    }
    if (-not (Test-Path $DumpPre)) {
        $overall = $false
        $fails.Add('Phase 1: pre-wipe dump file not created - positive control cannot be established.')
        Write-Host '[track4-pmemsave] FAIL: pre-wipe dump file not created.' -ForegroundColor Red
    } else {
        $preBytes = [System.IO.File]::ReadAllBytes($DumpPre)
        Write-Host "  Pre-wipe dump: $([Math]::Round($preBytes.Length/1MB,1)) MiB" -ForegroundColor Gray

        # Search for MEMKEY01 fallback constant - should be ABSENT in a healthy
        # run (means RDRAND/RDTSC entropy succeeded; fallback never stored).
        # If found, it just means entropy fell back - not a security failure, but noteworthy.
        $preMemkeyHits = Search-BytePattern $preBytes $SentinelMemkey01
        if ($preMemkeyHits.Count -gt 0) {
            Write-Host "  [INFO] MEMKEY01 fallback found at $($preMemkeyHits.Count) location(s) in pre-wipe dump." -ForegroundColor DarkYellow
            Write-Host '         This means nx_mem_key_ensure fell back to the weak-entropy guard.' -ForegroundColor DarkYellow
            Write-Host '         Expected on QEMU TCG (no RDRAND). Not a security failure on TCG.' -ForegroundColor DarkYellow
        } else {
            Write-Host '  MEMKEY01 not found in pre-wipe dump (good - entropy succeeded).' -ForegroundColor Green
        }

        # Positive control: prove the exact must-vanish bytes were live in DRAM
        # before accepting their absence after the wipe.
        $presentHits = Search-BytePattern $preBytes $SentinelBytes
        if ($presentHits.Count -gt 0) {
            Write-Host "  [B0] Runtime sentinel '$SentinelString' FOUND pre-wipe at $($presentHits.Count) offset(s). (PASS)" -ForegroundColor Green
        } else {
            $overall = $false
            $fails.Add("Phase 1 Assertion B0: runtime sentinel '$SentinelString' absent from PRE-WIPE dump - positive control failed.")
            Write-Host "  [B0] FAIL: runtime sentinel '$SentinelString' absent from pre-wipe dump." -ForegroundColor Red
        }

        # If canary token was extracted from serial, search for it as a byte pattern
        if ($canaryToken -and $canaryToken -match '0x([0-9A-Fa-f]+)') {
            $hexStr = $Matches[1].PadLeft(16, '0')
            $canaryBytes = [byte[]]@()
            for ($i = 0; $i -lt $hexStr.Length; $i += 2) {
                $canaryBytes += [byte][Convert]::ToInt32($hexStr.Substring($i,2), 16)
            }
            $preCanaryHits = Search-BytePattern $preBytes $canaryBytes
            if ($preCanaryHits.Count -gt 0) {
                Write-Host "  Canary token bytes FOUND in pre-wipe dump ($($preCanaryHits.Count) hits) - expected (live secret in DRAM)." -ForegroundColor Gray
            } else {
                Write-Host "  [INFO] Canary token not found in pre-wipe dump (may be in RO pages or register only)." -ForegroundColor DarkGray
            }
        }
        Write-Host '[track4-pmemsave] Phase 1 complete (pre-wipe baseline captured).' -ForegroundColor Green
    }

    # ------------------------------------------------------------------
    # Phase 2 - Trigger wipe and post-wipe dump
    # ------------------------------------------------------------------
    Write-Host ''
    Write-Host '--- Phase 2: Trigger nx_volatile_wipe_halt via serial w command ---' -ForegroundColor Cyan
    Write-Host '    Sending serial command w -> nx_volatile_wipe_halt()...' -ForegroundColor Yellow

    # The COM1 automation channel requires the 0x01 "arm" prefix before the
    # command byte; 'w' = CMD_WIPE in serial_dispatch_control (ASCII 0x77).
    Send-SerialByte $serialClient 0x01
    Send-SerialByte $serialClient 0x77

    # Wait for [WIPED] confirmation
    Write-Host '    Waiting for [WIPED] marker...' -ForegroundColor Yellow
    $wipeLog = Read-SerialUntilMarker $serialClient '[WIPED]' $WipeTimeoutSec
    Add-Content -Path $SerialLog -Value $wipeLog

    if (-not $wipeLog.Contains('[WIPED]')) {
        $overall = $false
        $fails.Add('Phase 2: [WIPED] marker not received - nx_volatile_wipe_halt may not have run (debug serial build required).')
        Write-Host '[track4-pmemsave] WARN: [WIPED] marker not seen in serial output.' -ForegroundColor DarkYellow
        Write-Host '  If this is a non-debug build (ENABLE_DEBUG_SERIAL off), [WIPED] is not emitted.' -ForegroundColor DarkYellow
        Write-Host '  Proceeding with post-wipe dump anyway (scrub happens regardless).' -ForegroundColor DarkYellow
    } else {
        Write-Host '[track4-pmemsave] [WIPED] received - scrub completed before post-wipe dump.' -ForegroundColor Green
    }

    # Give a moment for the HLT loop to settle, then dump
    Start-Sleep -Seconds 2

    Write-Host "--- Phase 2 (continued): Post-wipe pmemsave (${DumpSizeMB} MiB -> $DumpPost) ---" -ForegroundColor Cyan

    if (Test-Path $DumpPost) { Remove-Item $DumpPost -Force }
    Send-MonitorCmd "pmemsave 0 $DumpSizeHex `"$($DumpPost -replace '\\','/')`"" -WaitMs (15 * 1000)

    $postDumpDeadline = [DateTime]::UtcNow.AddSeconds(25)
    while (-not (Test-Path $DumpPost) -and [DateTime]::UtcNow -lt $postDumpDeadline) {
        Start-Sleep -Milliseconds 500
    }

    if (-not (Test-Path $DumpPost)) {
        $overall = $false
        $fails.Add('Phase 2: post-wipe dump file not created - monitor pmemsave failed.')
        Write-Host '[track4-pmemsave] FAIL: post-wipe dump not created.' -ForegroundColor Red
    } else {
        $postBytes = [System.IO.File]::ReadAllBytes($DumpPost)
        Write-Host "  Post-wipe dump: $([Math]::Round($postBytes.Length/1MB,1)) MiB" -ForegroundColor Gray

        # --- Assertion A: MEMKEY01 must NOT appear in post-wipe dump ---
        # nx_volatile_scrub_secrets zeroes nx_mem_key at the very start.
        # Finding MEMKEY01 post-wipe means the scrub missed the mem-key region.
        $postMemkeyHits = Search-BytePattern $postBytes $SentinelMemkey01
        if ($postMemkeyHits.Count -gt 0) {
            $overall = $false
            $fails.Add("Phase 2 Assertion A: MEMKEY01 fallback found at $($postMemkeyHits.Count) offset(s) in POST-WIPE dump - nx_mem_key region was NOT zeroed. Scrub regression!")
            Write-Host "[track4-pmemsave] FAIL: MEMKEY01 found in post-wipe dump at offsets: $($postMemkeyHits[0..([Math]::Min(4,$postMemkeyHits.Count)-1)] -join ', ')..." -ForegroundColor Red
        } else {
            Write-Host '  [A] MEMKEY01 absent from post-wipe dump. (PASS - mem-key region zeroed)' -ForegroundColor Green
        }

        # --- Assertion B: runtime-planted sentinel must vanish post-wipe ---
        $postSentHits = Search-BytePattern $postBytes $SentinelBytes
        if ($postSentHits.Count -gt 0) {
            $overall = $false
            $fails.Add("Phase 2 Assertion B: runtime sentinel '$SentinelString' remains at $($postSentHits.Count) offset(s) in POST-WIPE dump.")
            Write-Host "  [B] FAIL: runtime sentinel remains post-wipe ($($postSentHits.Count) hits)." -ForegroundColor Red
        } else {
            Write-Host "  [B] Runtime sentinel '$SentinelString' absent post-wipe. (PASS - planted secret erased)" -ForegroundColor Green
        }

        # --- Assertion C: Canary token bytes must NOT appear post-wipe ---
        if ($canaryToken -and $canaryToken -match '0x([0-9A-Fa-f]+)') {
            $hexStr = $Matches[1].PadLeft(16, '0')
            $canaryBytes = [byte[]]@()
            for ($i = 0; $i -lt $hexStr.Length; $i += 2) {
                $canaryBytes += [byte][Convert]::ToInt32($hexStr.Substring($i,2), 16)
            }
            $postCanaryHits = Search-BytePattern $postBytes $canaryBytes
            if ($postCanaryHits.Count -gt 0) {
                $overall = $false
                $fails.Add("Phase 2 Assertion C: kernel_canary bytes still present in post-wipe dump at $($postCanaryHits.Count) location(s). Scrub may have missed the canary region.")
                Write-Host "[track4-pmemsave] FAIL: canary token found in post-wipe dump ($($postCanaryHits.Count) hits)!" -ForegroundColor Red
                Write-Host '  This indicates nx_volatile_scrub_secrets did not reach the kernel_canary symbol.' -ForegroundColor Red
            } else {
                Write-Host '  [C] Canary token bytes absent from post-wipe dump. (PASS - canary zeroed)' -ForegroundColor Green
            }
        } else {
            Write-Host '  [C] No canary token to check (non-debug build or token not emitted in serial).' -ForegroundColor DarkGray
            Write-Host '      Per-boot canary scrub is structurally confirmed by the symbol audit.' -ForegroundColor DarkGray
        }

        # --- Informational: document what IS in the post-wipe dump ---
        Write-Host ''
        Write-Host '  Documented residuals in post-wipe dump (expected, NOT failures):' -ForegroundColor DarkGray
        # Check for OVMF firmware string (always present, irreducible firmware residual)
        $ovmfBytes  = [System.Text.Encoding]::ASCII.GetBytes('BdsDxe')
        $ovmfHits   = Search-BytePattern $postBytes $ovmfBytes
        if ($ovmfHits.Count -gt 0) {
            Write-Host "    UEFI firmware ('BdsDxe') present: $($ovmfHits.Count) hits - OVMF text, irreducible." -ForegroundColor DarkGray
        }
        # Check for kernel code identity string (always in .text, not scrubbed)
        $gritBytes = [System.Text.Encoding]::ASCII.GetBytes('Grit')
        $gritHits  = Search-BytePattern $postBytes $gritBytes
        if ($gritHits.Count -gt 0) {
            Write-Host "    Kernel string ('Grit') present: $($gritHits.Count) hits - kernel .text, documented live residual." -ForegroundColor DarkGray
        }
        Write-Host '    These residuals are named in docs/track4-ram-secure-erasure-todo.md §Part A "HARD LIMIT".' -ForegroundColor DarkGray
    }

    # ------------------------------------------------------------------
    # Summary
    # ------------------------------------------------------------------
    Write-Host ''
    Write-Host '============================================================' -ForegroundColor Cyan
    if ($overall) {
        Write-Host ' Track 4 pmemsave test: PASS' -ForegroundColor Green
        Write-Host ' Post-wipe DRAM image contains no must-vanish secret material.' -ForegroundColor Green
        Write-Host ''
        Write-Host ' What was tested:' -ForegroundColor Gray
        Write-Host '  - nx_volatile_wipe_halt() triggered via serial w command' -ForegroundColor Gray
        Write-Host '  - [WIPED] confirmation marker received (debug build)' -ForegroundColor Gray
        Write-Host '  - Runtime-only sentinel present before wipe and absent afterward' -ForegroundColor Gray
        Write-Host '  - MEMKEY01 fallback constant absent from post-wipe dump' -ForegroundColor Gray
        Write-Host '  - Canary token bytes absent from post-wipe dump (if available)' -ForegroundColor Gray
        Write-Host ''
        Write-Host ' Documented residuals (irreducible, per track doc Part A):' -ForegroundColor DarkGray
        Write-Host '  - Kernel .text, UEFI firmware, page tables remain in DRAM' -ForegroundColor DarkGray
        Write-Host '  - These are the named live-working-set residual; not claimed absent' -ForegroundColor DarkGray
        Write-Host ''
        Write-Host ' HARDWARE CAVEAT: QEMU TCG does NOT test TME/SME FME.' -ForegroundColor DarkYellow
        Write-Host '   Software scrub layer only. Part C requires real silicon.' -ForegroundColor DarkYellow
        Write-Host "  Pre-wipe dump:  $DumpPre" -ForegroundColor Gray
        Write-Host "  Post-wipe dump: $DumpPost" -ForegroundColor Gray
        Write-Host "  Serial log:     $SerialLog" -ForegroundColor Gray
        Write-Host '============================================================' -ForegroundColor Cyan
    } else {
        Write-Host ' Track 4 pmemsave test: FAILED' -ForegroundColor Red
        foreach ($f in $fails) { Write-Host "  - $f" -ForegroundColor Red }
        Write-Host '============================================================' -ForegroundColor Cyan
        exit 1
    }
} finally {
    if ($serialClient) { try { $serialClient.Close() } catch {} }
    Stop-QemuIfRunning
    if ($bootJob) {
        Stop-Job $bootJob -ErrorAction SilentlyContinue
        Remove-Job $bootJob -Force -ErrorAction SilentlyContinue
    }
}
