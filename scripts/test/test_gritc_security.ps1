$ErrorActionPreference = 'Stop'

$Root = Resolve-Path (Join-Path $PSScriptRoot '..\..')
$Compiler = Join-Path $Root 'src\user\grithl\compiler\gritc.py'
$LibDir = Join-Path $Root 'src\user\grithl\lib'
$OutDir = Join-Path $Root 'build\ghl\tests'

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

Write-Host '[gritc-security] compile zero-asm kernel intrinsic fixture' -ForegroundColor Yellow
python $Compiler `
    (Join-Path $Root 'tests\ghl_kernel\noasm_intrinsics.ghl') `
    -o (Join-Path $OutDir 'noasm_intrinsics.asm') `
    -L $LibDir --target kernel --embed --forbid-asm
if ($LASTEXITCODE -ne 0) {
    throw 'zero-asm kernel intrinsic fixture failed to compile'
}

Write-Host '[gritc-security] compile exact-authority kernel cap fixture (narrow caps only)' -ForegroundColor Yellow
python $Compiler `
    (Join-Path $Root 'tests\ghl_kernel\exact_authority_caps.ghl') `
    -o (Join-Path $OutDir 'exact_authority_caps.asm') `
    -L $LibDir --target kernel --embed --forbid-asm
if ($LASTEXITCODE -ne 0) {
    throw 'exact-authority kernel cap fixture failed to compile with narrow caps'
}

Write-Host '[gritc-security] reject privileged intrinsic held under the wrong exact authority' -ForegroundColor Yellow
$OldEAP2 = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
python $Compiler `
    (Join-Path $Root 'tests\ghl_kernel\exact_authority_wrong.ghl') `
    -o (Join-Path $OutDir 'exact_authority_wrong.asm') `
    -L $LibDir --target kernel --embed *> $null
$WrongAuthExit = $LASTEXITCODE
$ErrorActionPreference = $OldEAP2
if ($WrongAuthExit -eq 0) {
    throw 'exact-authority gate accepted lgdt() while only kernel_creg was declared'
}

Write-Host '[gritc-security] reject privileged intrinsic from a ring-3 user app' -ForegroundColor Yellow
# Proves user apps cannot request privileged intrinsics: the gate keys off the
# build target, so write_cr0() is rejected under --target user even though the
# fixture declares the matching kernel_creg authority.
$OldEAP3 = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
python $Compiler `
    (Join-Path $Root 'tests\ghl_kernel\user_privileged_forbidden.ghl') `
    -o (Join-Path $OutDir 'user_privileged_forbidden.asm') `
    -L $LibDir *> $null
$UserPrivExit = $LASTEXITCODE
$ErrorActionPreference = $OldEAP3
if ($UserPrivExit -eq 0) {
    throw 'user target accepted write_cr0() (privileged intrinsic leaked into a ring-3 app)'
}

Write-Host '[gritc-security] reject raw memory builtin without the raw_mem capability' -ForegroundColor Yellow
$OldEAP4 = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
python $Compiler `
    (Join-Path $Root 'tests\ghl_kernel\raw_mem_forbidden.ghl') `
    -o (Join-Path $OutDir 'raw_mem_forbidden.asm') `
    -L $LibDir --target kernel --embed *> $null
$RawMemDenyExit = $LASTEXITCODE
$ErrorActionPreference = $OldEAP4
if ($RawMemDenyExit -eq 0) {
    throw 'kernel target accepted sq() raw store without unsafe raw_mem'
}

Write-Host '[gritc-security] accept the same raw store once raw_mem is declared' -ForegroundColor Yellow
# Positive companion: proves the gate keys off the capability, not the builtin.
python $Compiler `
    (Join-Path $Root 'tests\ghl_kernel\raw_mem_caps.ghl') `
    -o (Join-Path $OutDir 'raw_mem_caps.asm') `
    -L $LibDir --target kernel --embed
if ($LASTEXITCODE -ne 0) {
    throw 'raw_mem fixture failed to compile with the raw_mem capability declared'
}

Write-Host '[gritc-security] === Track-8 G1: --target driver holds no ambient HW authority ===' -ForegroundColor Cyan
# A driver-host process must reach hardware ONLY through the broker. The driver
# target forces --forbid-asm + --deny-unsafe and, being ring-3, cannot emit any
# privileged intrinsic. Prove: (a) a clean broker-only driver compiles, (b) a raw
# port write is rejected, (c) a raw MMIO/raw_mem boundary declaration is rejected.

Write-Host '[gritc-security] driver target: clean broker-only driver compiles' -ForegroundColor Yellow
python $Compiler `
    (Join-Path $Root 'tests\ghl_kernel\driver_target_ok.ghl') `
    -o (Join-Path $OutDir 'driver_target_ok.asm') `
    -L $LibDir --target driver
if ($LASTEXITCODE -ne 0) {
    throw 'driver target rejected a clean broker-only driver (G1 gate too strict)'
}

Write-Host '[gritc-security] driver target: reject raw port I/O' -ForegroundColor Yellow
$OldEAPd1 = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
python $Compiler `
    (Join-Path $Root 'tests\ghl_kernel\driver_target_no_io.ghl') `
    -o (Join-Path $OutDir 'driver_target_no_io.asm') `
    -L $LibDir --target driver *> $null
$DrvIoExit = $LASTEXITCODE
$ErrorActionPreference = $OldEAPd1
if ($DrvIoExit -eq 0) {
    throw 'driver target accepted outb() (G1 violated: a driver gained direct port authority)'
}

Write-Host '[gritc-security] driver target: reject raw MMIO / raw_mem boundary' -ForegroundColor Yellow
$OldEAPd2 = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
python $Compiler `
    (Join-Path $Root 'tests\ghl_kernel\driver_target_no_mmio.ghl') `
    -o (Join-Path $OutDir 'driver_target_no_mmio.asm') `
    -L $LibDir --target driver *> $null
$DrvMmioExit = $LASTEXITCODE
$ErrorActionPreference = $OldEAPd2
if ($DrvMmioExit -eq 0) {
    throw 'driver target accepted an unsafe raw_mem declaration (G1 violated: a driver could map MMIO)'
}

Write-Host '[gritc-security] driver target: HDA class driver compiles broker-only' -ForegroundColor Yellow
python $Compiler `
    (Join-Path $Root 'src\drivers\audio\hda.ghl') `
    -o (Join-Path $OutDir 'hda.asm') `
    -L $LibDir --target driver
if ($LASTEXITCODE -ne 0) {
    throw 'HDA class driver failed to compile under --target driver'
}

Write-Host '[gritc-security] driver target: Rung 2/3 drivers compile broker-only' -ForegroundColor Yellow
foreach ($t8drv in @('src\drivers\acpi_ec\battery.ghl', 'src\drivers\net\rtl8156.ghl')) {
    python $Compiler `
        (Join-Path $Root $t8drv) `
        -o (Join-Path $OutDir ([System.IO.Path]::GetFileNameWithoutExtension($t8drv) + '.asm')) `
        -L $LibDir --target driver
    if ($LASTEXITCODE -ne 0) {
        throw "Track-8 driver failed to compile under --target driver: $t8drv"
    }
}

Write-Host '[gritc-security] reject an unknown unsafe capability declaration' -ForegroundColor Yellow
# Proves the unsafe-capability namespace is a closed allowlist: a typo'd or
# invented authority is a hard parse error, never a silently-ignored gate.
$OldEAP5 = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
python $Compiler `
    (Join-Path $Root 'tests\ghl_kernel\unknown_cap_forbidden.ghl') `
    -o (Join-Path $OutDir 'unknown_cap_forbidden.asm') `
    -L $LibDir --target kernel --embed *> $null
$UnknownCapExit = $LASTEXITCODE
$ErrorActionPreference = $OldEAP5
if ($UnknownCapExit -eq 0) {
    throw 'compiler accepted an unknown unsafe capability declaration'
}

Write-Host '[gritc-security] compile guarded boot layout fixture' -ForegroundColor Yellow
python $Compiler `
    (Join-Path $Root 'tests\ghl_boot\boot_layout.ghl') `
    -o (Join-Path $OutDir 'boot_layout.asm') `
    -L $LibDir --target boot --embed
if ($LASTEXITCODE -ne 0) {
    throw 'boot layout fixture failed to compile'
}

$bootAsm = Get-Content -Path (Join-Path $OutDir 'boot_layout.asm') -Raw
if ($bootAsm -notmatch 'bits 16' -or $bootAsm -notmatch 'org 0x7C00') {
    throw 'boot layout fixture did not emit expected bits/org directives'
}

Write-Host '[gritc-security] compile structured boot function fixture' -ForegroundColor Yellow
python $Compiler `
    (Join-Path $Root 'tests\ghl_boot\boot_fn.ghl') `
    -o (Join-Path $OutDir 'boot_fn.asm') `
    -L $LibDir --target boot --embed
if ($LASTEXITCODE -ne 0) {
    throw 'structured boot function fixture failed to compile'
}

# Regression (PR #22 review): a multi-register boot call (ah/al/bx ...) must
# stage every argument before writing any target register, so a register set
# early (ah) can't be clobbered by a later arg's accumulator load. After the
# fix the targets are popped in reverse, so ah is written on the line directly
# before the BIOS call. If the inline-write bug returns, a `mov ax, <imm>` for a
# later arg lands between the ah write and the call and this match fails.
Write-Host '[gritc-security] boot regcall stages args without clobber (ah preserved)' -ForegroundColor Yellow
$bootFnAsm = Get-Content -Path (Join-Path $OutDir 'boot_fn.asm') -Raw
if ($bootFnAsm -notmatch '(?m)^\s*mov ah, \w+\s*\r?\n\s*call bios_teletype\b') {
    throw 'boot regcall regression: AH is not set immediately before the BIOS call (argument staging clobber)'
}

$Nasm = 'C:\Tools\nasm-2.16.03\nasm.exe'
if (-not (Test-Path $Nasm)) {
    $cmd = Get-Command nasm -ErrorAction SilentlyContinue
    if ($cmd) { $Nasm = $cmd.Source }
}
if (Test-Path $Nasm) {
    & $Nasm -f bin -o (Join-Path $OutDir 'boot_fn.bin') (Join-Path $OutDir 'boot_fn.asm')
    if ($LASTEXITCODE -ne 0) {
        throw 'structured boot function fixture failed to assemble with NASM'
    }

    # Regression (PR #22 review, P2): byte-register boot calls must pick a legacy
    # byte scratch (al/bl/cl/dl), never sil/dil/bpl (REX-only, unassemblable in
    # bits 16/32). This fixture's targets occupy rbx/rcx/rdx, forcing scratch to
    # rax; the pre-fix code emitted `mov bl, sil` and failed to assemble here.
    Write-Host '[gritc-security] byte-register boot call uses an encodable legacy scratch' -ForegroundColor Yellow
    python $Compiler `
        (Join-Path $Root 'tests\ghl_boot\boot_byte_regs.ghl') `
        -o (Join-Path $OutDir 'boot_byte_regs.asm') `
        -L $LibDir --target boot --embed
    if ($LASTEXITCODE -ne 0) {
        throw 'byte-register boot call fixture failed to compile'
    }
    & $Nasm -f bin -o (Join-Path $OutDir 'boot_byte_regs.bin') (Join-Path $OutDir 'boot_byte_regs.asm')
    if ($LASTEXITCODE -ne 0) {
        throw 'byte-register boot call fixture failed to assemble with NASM (non-encodable scratch register)'
    }

    Write-Host '[gritc-security] compile and assemble exact boot sector fixture' -ForegroundColor Yellow
    python $Compiler `
        (Join-Path $Root 'tests\ghl_boot\boot_sector.ghl') `
        -o (Join-Path $OutDir 'boot_sector.asm') `
        -L $LibDir --target boot --embed
    if ($LASTEXITCODE -ne 0) {
        throw 'boot sector fixture failed to compile'
    }
    & $Nasm -f bin -o (Join-Path $OutDir 'boot_sector.bin') (Join-Path $OutDir 'boot_sector.asm')
    if ($LASTEXITCODE -ne 0) {
        throw 'boot sector fixture failed to assemble with NASM'
    }
    $sector = [System.IO.File]::ReadAllBytes((Join-Path $OutDir 'boot_sector.bin'))
    if ($sector.Length -ne 512) {
        throw "boot sector fixture size was $($sector.Length), expected 512"
    }
    if ($sector[510] -ne 0x55 -or $sector[511] -ne 0xAA) {
        throw 'boot sector fixture did not end with 55 AA signature'
    }

    Write-Host '[gritc-security] compile + assemble A20 port-IO boot leaf (zero-asm migration)' -ForegroundColor Yellow
    python $Compiler `
        (Join-Path $Root 'tests\ghl_boot\a20_wait.ghl') `
        -o (Join-Path $OutDir 'a20_wait.asm') `
        -L $LibDir --target boot --forbid-asm
    if ($LASTEXITCODE -ne 0) {
        throw 'a20_wait boot leaf failed to compile under --forbid-asm'
    }
    & $Nasm -f bin -o (Join-Path $OutDir 'a20_wait.bin') (Join-Path $OutDir 'a20_wait.asm')
    if ($LASTEXITCODE -ne 0) {
        throw 'a20_wait boot leaf failed to assemble with NASM'
    }
    # It is a declared I/O boundary (unsafe boot_io) -> --deny-unsafe must reject.
    $OldEAP = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    python $Compiler `
        (Join-Path $Root 'tests\ghl_boot\a20_wait.ghl') `
        -o (Join-Path $OutDir 'a20_wait_deny.asm') `
        -L $LibDir --target boot --deny-unsafe *> $null
    $A20DenyExit = $LASTEXITCODE
    $ErrorActionPreference = $OldEAP
    if ($A20DenyExit -eq 0) {
        throw '--deny-unsafe accepted the a20_wait I/O boundary module'
    }
} else {
    Write-Host '[gritc-security] NASM not found; skipped boot_fn assembly check' -ForegroundColor DarkYellow
}

Write-Host '[gritc-security] reject inline asm under --forbid-asm' -ForegroundColor Yellow
$OldErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
python $Compiler `
    (Join-Path $Root 'tests\ghl_kernel\asm_forbidden.ghl') `
    -o (Join-Path $OutDir 'asm_forbidden.asm') `
    -L $LibDir --target kernel --embed --forbid-asm *> $null
$RejectForbidAsmExit = $LASTEXITCODE
$ErrorActionPreference = $OldErrorActionPreference
if ($RejectForbidAsmExit -eq 0) {
    throw '--forbid-asm accepted an inline asm block'
}

Write-Host '[gritc-security] reject inline asm under --target boot' -ForegroundColor Yellow
$OldErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
python $Compiler `
    (Join-Path $Root 'tests\ghl_kernel\asm_forbidden.ghl') `
    -o (Join-Path $OutDir 'asm_forbidden_boot.asm') `
    -L $LibDir --target boot --embed *> $null
$RejectBootAsmExit = $LASTEXITCODE
$ErrorActionPreference = $OldErrorActionPreference
if ($RejectBootAsmExit -eq 0) {
    throw '--target boot accepted an inline asm block'
}

Write-Host '[gritc-security] reject boot unsafe operation without capability' -ForegroundColor Yellow
$OldErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
python $Compiler `
    (Join-Path $Root 'tests\ghl_boot\boot_unsafe_forbidden.ghl') `
    -o (Join-Path $OutDir 'boot_unsafe_forbidden.asm') `
    -L $LibDir --target boot --embed *> $null
$RejectBootUnsafeExit = $LASTEXITCODE
$ErrorActionPreference = $OldErrorActionPreference
if ($RejectBootUnsafeExit -eq 0) {
    throw '--target boot accepted intn() without unsafe boot_int'
}

Write-Host '[gritc-security] reject declared unsafe under --deny-unsafe' -ForegroundColor Yellow
$OldErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
python $Compiler `
    (Join-Path $Root 'tests\ghl_boot\boot_unsafe_decl.ghl') `
    -o (Join-Path $OutDir 'boot_unsafe_decl.asm') `
    -L $LibDir --target boot --embed --deny-unsafe *> $null
$RejectDenyUnsafeExit = $LASTEXITCODE
$ErrorActionPreference = $OldErrorActionPreference
if ($RejectDenyUnsafeExit -eq 0) {
    throw '--deny-unsafe accepted unsafe capability declarations'
}

Write-Host '[gritc-security] optimizer (-O1) is signature-preserving and lossless-shape' -ForegroundColor Yellow
# Differential safety net for the function-level optimizer: for every shipped
# user app, compile with the optimizer OFF (--O0) and ON (default), and assert
#   (1) the .sig.json sidecar is byte-identical  -> the public ABI surface and
#       every function's arity/kind/return are unchanged, and
#   (2) the optimized output is never larger      -> the pass only ever removes
#       provably-dead scaffolding, never adds code.
# A regression that changes a signature or grows output trips this immediately.
$AppDir = Join-Path $Root 'src\user\grithl\apps'
$AppLib = Join-Path $Root 'src\user\grithl\lib'
# Use a throwaway scratch dir OUTSIDE build/ghl: the signature-registry builder
# scans build/ghl/** and would flag these comparison copies as duplicate
# FN_BEGIN names against the real generated apps.
$DiffDir = Join-Path ([IO.Path]::GetTempPath()) ("gritc_optdiff_" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $DiffDir -Force | Out-Null
try {
    Get-ChildItem -Path $AppDir -Filter '*.ghl' | ForEach-Object {
        $nm = [IO.Path]::GetFileNameWithoutExtension($_.Name)
        $o0 = Join-Path $DiffDir "$nm.O0.asm"
        $o1 = Join-Path $DiffDir "$nm.O1.asm"
        $o2 = Join-Path $DiffDir "$nm.O2.asm"
        python $Compiler $_.FullName -o $o0 -L $AppLib --emit-sigs --O0 *> $null
        if ($LASTEXITCODE -ne 0) { throw "optimizer diff: --O0 compile failed for $nm" }
        python $Compiler $_.FullName -o $o1 -L $AppLib --emit-sigs *> $null
        if ($LASTEXITCODE -ne 0) { throw "optimizer diff: -O1 compile failed for $nm" }
        python $Compiler $_.FullName -o $o2 -L $AppLib --emit-sigs --O2 *> $null
        if ($LASTEXITCODE -ne 0) { throw "optimizer diff: --O2 compile failed for $nm" }
        $sig0 = Get-Content ([IO.Path]::ChangeExtension($o0, '.sig.json')) -Raw
        $sig1 = Get-Content ([IO.Path]::ChangeExtension($o1, '.sig.json')) -Raw
        $sig2 = Get-Content ([IO.Path]::ChangeExtension($o2, '.sig.json')) -Raw
        if ($sig0 -ne $sig1) { throw "optimizer changed the signature sidecar for $nm" }
        # Phase-2 (--O2) register allocator must be signature-preserving too:
        # only .text may change, never the public ABI sidecar.
        if ($sig0 -ne $sig2) { throw "--O2 register allocator changed the signature sidecar for $nm" }
        if ((Get-Item $o1).Length -gt (Get-Item $o0).Length) {
            throw "optimizer GREW output for $nm (-O1 larger than --O0)"
        }
        if ((Get-Item $o2).Length -gt (Get-Item $o0).Length) {
            throw "--O2 GREW output for $nm (larger than --O0)"
        }
    }

    $syscallFixture = Join-Path $DiffDir 'syscall_clobber.ghl'
    $syscallAsm = Join-Path $DiffDir 'syscall_clobber.asm'
    @'
app "probe" { stack = 4096; }
fn probe(x) {
    syscall(1, 0);
    return x;
}
'@ | Set-Content -Encoding ascii $syscallFixture
    python $Compiler $syscallFixture -o $syscallAsm -L $AppLib --emit-sigs *> $null
    if ($LASTEXITCODE -ne 0) { throw "optimizer syscall-clobber fixture failed to compile" }
    $syscallOut = Get-Content $syscallAsm -Raw
    if ($syscallOut -notmatch 'syscall\s+mov rax, \[rbp-8\]') {
        throw "optimizer forwarded an rbp-slot value across syscall; caller-saved syscall registers must be treated as clobbered"
    }
    if ($syscallOut -notmatch 'push rbx\s+push r12[\s\S]*syscall[\s\S]*pop r12\s+pop rbx') {
        throw "optimizer removed the rbx/r12 user-mode compatibility bracket around a syscall-bearing function"
    }
} finally {
    Remove-Item -Recurse -Force $DiffDir -ErrorAction SilentlyContinue
}

Write-Host '[gritc-security] reserve NAME[N] is zero-cost (.bss/NOBITS, no image bytes)' -ForegroundColor Yellow
# The `reserve` primitive must lower a large uninitialized arena into `.bss`
# (NOBITS) so it costs ZERO output bytes - this is what makes a multi-MiB
# per-slot XML DOM hostable in zero-asm GHL without bloating KERNEL.BIN.
$ReserveDir = Join-Path ([IO.Path]::GetTempPath()) ("gritc_reserve_" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $ReserveDir -Force | Out-Null
try {
    $rsrc = Join-Path $ReserveDir 'reserve.ghl'
    $rasm = Join-Path $ReserveDir 'reserve.asm'
    @'
module "rsv";
unsafe raw_mem;
unsafe implicit_extern;
reserve big[3145728];
fn rsv_touch(i) {
    sb(&big + i, 7);
    return lb(&big + i);
}
'@ | Set-Content -Encoding ascii $rsrc
    python $Compiler $rsrc -o $rasm -L $LibDir --target kernel --embed --forbid-asm
    if ($LASTEXITCODE -ne 0) { throw 'reserve fixture failed to compile under --target kernel --forbid-asm' }
    $rout = Get-Content $rasm -Raw
    if ($rout -notmatch '(?m)^\s*section \.bss') {
        throw 'reserve did not emit a .bss section'
    }
    if ($rout -notmatch '(?m)resb 3145728') {
        throw 'reserve did not emit `resb 3145728` into .bss (must be uninitialized/NOBITS)'
    }
    if ($rout -match '(?m)times 3145728 db 0') {
        throw 'reserve emitted initialized image bytes (`times N db 0`) instead of NOBITS .bss'
    }
    # Prove zero-cost: assemble with NASM -f bin and confirm the binary is far
    # smaller than the 3 MiB arena (it occupies address space, not file bytes).
    if (Test-Path $Nasm) {
        $rbin = Join-Path $ReserveDir 'reserve.bin'
        # Embed output has no `bits/section` preamble; wrap it for a standalone -f bin build.
        $rwrap = Join-Path $ReserveDir 'reserve_wrap.asm'
        @"
bits 64
section .text
%include "$($rasm -replace '\\','/')"
"@ | Set-Content -Encoding ascii $rwrap
        & $Nasm -f bin -o $rbin $rwrap
        if ($LASTEXITCODE -ne 0) { throw 'reserve fixture failed to assemble with NASM -f bin' }
        $rsz = (Get-Item $rbin).Length
        if ($rsz -ge 3145728) {
            throw "reserve arena bloated the binary to $rsz bytes (>= 3 MiB); .bss is not zero-cost"
        }
        Write-Host "  OK - 3 MiB reserve -> $rsz byte binary (zero image cost)" -ForegroundColor Green
    }
    # Negative: `reserve` must be rejected for --target boot (no .bss in a flat
    # boot sector / org-based layout).
    $OldEAPr = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    python $Compiler $rsrc -o (Join-Path $ReserveDir 'reserve_boot.asm') -L $LibDir --target boot --embed *> $null
    $ReserveBootExit = $LASTEXITCODE
    $ErrorActionPreference = $OldEAPr
    if ($ReserveBootExit -eq 0) {
        throw 'reserve was accepted under --target boot'
    }
} finally {
    Remove-Item -Recurse -Force $ReserveDir -ErrorAction SilentlyContinue
}

Write-Host '[gritc-security] PASS' -ForegroundColor Green
