# Track 5 - All-Vendor Hardware Separation Monitor (the irreducible-hardware tier)

Goal: provide the **two guarantees that software alone cannot** - and provide them
on **every virtualization-capable ISA** behind one vendor-neutral interface, so
Grit gets maximum hardware compatibility instead of being Intel-only. This is
the hardware half of `docs/The final goal after the rest.txt`. Everything in that
goal file that does NOT require hardware moves to **Track 6** (the compartmentalized
software "-1" monitor); this track is *only* the residual that genuinely needs
silicon.

The two irreducible-hardware guarantees (established in the Track 6 analysis):

- **G1 - Privilege below ring-0 (un-disableable floor).** A software monitor lives
  at the same privilege as the kernel it guards, so a compromised ring-0 can
  `clear CR0.WP` / rewrite CR3 / execute privileged instructions to disable it.
  Only a mode *beneath* ring-0 can trap those. This is what makes the Track 6
  compartments un-disableable rather than merely expensive-to-disable. (Also
  closes the existing nk_monitor SMP/AP gap where APs run with WP=0.)
- **G2 - Device-DMA confinement.** A malicious device DMAs straight to physical
  RAM, bypassing the CPU MMU entirely. Only an IOMMU can stop it. No CPU-side
  software substitute exists.

Per `architecture-defense-in-depth.md` design rule 3, this tier is **opportunistic**:
where the hardware exists it is detected and armed; where it does not (QEMU-TCG,
no-IOMMU boards, virt disabled in firmware) the system stays safe on the Track 6
software floor with the two residuals documented honestly. Hardware is hardening,
never a prerequisite for safety.

Maps to `docs/ghl-beyond-zero-trust-todo.md` → "P0: Compromised Kernel And
Hypervisor Containment" + Kill-Chain "opportunistic monitor/hypervisor tier".
Depends on Track 6 (the compartments are what this tier makes un-disableable) and
Track 2 (verify-before-map-executable).

---

## Honesty rule (non-negotiable)

Same discipline as Track 3. Maturity tags:

- `modeled` - code exists, logic exercised on host/compiler, fails closed.
- `tested-tcg` - exercised under QEMU **without** hardware virt (logic only:
  field encode/decode, page-table math, HAL dispatch). **Does NOT mean the
  hardware enforces anything** - TCG runs none of VMX-root / SVM / EL2 / H-mode.
- `tested-accel` - exercised where the relevant extension actually traps
  (KVM-nested, `-cpu host,+vmx/+svm`, ARM virt host, etc.).
- `tested-hw` - exercised on real silicon of that vendor.

We never claim hardware enforcement from a TCG boot, and never claim a vendor's
path works until it is at least `tested-accel` for that vendor. We never claim
safety after arbitrary total hardware compromise.

## Status legend
- [x] done at the stated maturity tag   [~] partial   [ ] not started

---

## The vendor-neutral monitor HAL (do this FIRST - it is the compatibility story)

Everything below plugs into one abstract interface so the rest of Grit, and
all of Track 6, are vendor-agnostic. Adding a new ISA = implementing the HAL, not
touching callers.

- [x] Define `mon_hal` interface (GHL, `--forbid-asm --deny-unsafe`): `detect()`,
      `enter_root()`, `make_guest(state)`, `second_stage_map(gpa, hpa, perms)`,
      `protect_region(region, perms)`, `trap_on(event-set)`, `iommu_map(dev, buf,
      perms)`, `iommu_fault_handler()`, `status()`. Vendor back-ends register
      against it. `modeled` / `tested-tcg`
      `src/tools/security/mon_hal.ghl` lands the vendor-neutral surface:
      `mon_hal_enter_root` (floor vs modeled-virt vs fail-closed bad-tier
      dispatch), the second-stage identity-map + W^X + carve-out math
      (`mon_hal_s2_map_perms` / `mon_hal_s2_check` / `mon_hal_region_is_monitor`),
      and the IOMMU DMA-confinement math (`mon_hal_iommu_translate`). The
      enforcement DECISIONS are pure functions of (entry perms, access type) and
      are vendor-INDEPENDENT (the "page-table math / HAL dispatch" the test
      boundary calls `tested-tcg`); exercised by `scripts/test/eval_mon_hal.py`
      (60 asserts) through the production gritc frontend, wired into
      `test_ghl_security_guards.ps1`. The per-vendor `make_guest` / VMLAUNCH /
      trap-exit half stays `tested-accel` (below).
- [x] Capability probe that selects a back-end at boot and publishes the chosen
      tier + per-feature availability via `SYS_SYSINFO` (200..240 range, same
      fail-soft pattern as CET/SMAP/KPTI/TME rows). `modeled`
      `mon_hal_select_backend` (in `src/tools/security/mon_hal_detect.ghl`) picks
      the tier from the per-vendor `*_usable` predicates; `mon_hal_status` maps it
      to a SYS_SYSINFO row.
- [x] Fallback contract: if `detect()` finds nothing, `mon_hal` reports
      `floor-only` and Track 6 runs unchanged on the software floor. `tested-tcg`
      `mon_hal_select_backend` returns `MONHAL_TIER_FLOOR_ONLY` for every
      non-virtualizable case and `mon_hal_status` reports `FLOOR_ONLY` (a distinct
      "software floor" row, never an error) - the only leg actually reachable on
      QEMU TCG.

---

## G1 - privilege-below-ring-0 interposition (per vendor)

For each vendor: bring up the root/hypervisor mode, run the existing kernel as a
guest under an identity second-stage map (so behavior is unchanged), then trap the
events that would let a compromised ring-0 disable the Track 6 compartments
(writes to CR0.WP / CR3 / CR4, EFER, page-table roots, illegal privileged insns).

### Intel VT-x
- [x] Detect: `CPUID.1:ECX.VMX[5]`, `IA32_FEATURE_CONTROL` lock + VMXON-outside-SMX;
      EPT/unrestricted-guest via `IA32_VMX_PROCBASED_CTLS2`. `modeled`
      `mon_hal_vmx_usable` (CPUID + FEATURE_CONTROL lock/outside-SMX semantics),
      `mon_hal_vmx_ept_supported` and `mon_hal_vmx_unrestricted_guest`
      (PROCBASED_CTLS2 high-dword allowed-1 bits 33/39).
- [x] VMXON region; VMCS for kernel-as-guest (capture CR/GDT/IDT/TR/RIP/RSP/RFLAGS;
      host-state → monitor). `modeled` / `tested-tcg`
      `src/tools/security/mon_hal_vmx_vmcs.ghl` lands the Intel VT-x capture
      MODEL: VMXON-region + VMCS-header well-formedness against `IA32_VMX_BASIC`
      (revision id, shadow bit, 4 KiB-aligned region size), the architectural
      VMCS field ENCODING + decode (access/index/type/width; guest-type 2 vs
      host-type 3 — GUEST_RIP 0x681E / HOST_RIP 0x6C16 reproduced from the SDM),
      the CR0/CR4 fixed-bit legality adjustment (`IA32_VMX_CR0/CR4_FIXED0/1`),
      and the security crux — the kernel-as-guest capture invariant: every
      required field present (`mon_hal_vmx_capture_complete`: CR0/CR3/CR4,
      GDTR/IDTR base+limit, TR sel+base, RIP/RSP/RFLAGS), GUEST state mirrors the
      live kernel (`mon_hal_vmx_guest_field_mirrors`, identity = behavior
      unchanged), and HOST state is rooted in the monitor and DISJOINT from the
      guest (`mon_hal_vmx_host_state_rooted_in_monitor`: host RIP/RSP inside the
      carve-out, host CR3 == monitor CR3 != guest CR3, so every VM-exit lands in
      the floor, never back in the compromised kernel). `mon_hal_vmx_make_guest_ok`
      folds the whole gate and fails closed. Pure policy (`--forbid-asm
      --deny-unsafe`, no privileged insn); exercised by
      `scripts/test/eval_mon_hal_vmx.py` (56 asserts) through the production gritc
      frontend, wired into `test_ghl_security_guards.ps1`. The real
      VMXON/VMPTRLD/VMWRITE/VMLAUNCH is the REAL back-end below.
- [~] Identity **EPT**; VMLAUNCH; exit handler resumes transparently. Markers
      `HVX+`/`HVX!`. `tested-accel`-PENDING (real code; needs an accel host run)
      `src/kernel/grithlk/mon_hal_vmx_backend.ghl` is the REAL VT-x back-end: it
      emits actual `VMXON / VMCLEAR / VMPTRLD / VMWRITE / VMLAUNCH / VMRESUME` via
      new gritc `kernel_vmx` intrinsics (+ `sgdt`/`sidt`/`str_sel` for descriptor
      capture; all NASM-verified). `vmx_backend_arm` enters root mode (legalizes
      CR0/CR4 to the fixed-bit MSRs, sets CR4.VMXE, configures FEATURE_CONTROL),
      loads a fresh VMCS, programs the full control/host/guest field set (controls
      via the allowed-0/1 `vmx_adjust_ctls` math, identity **EPT** pointer, host
      RIP = `vmx_exit_trampoline`, guest = mirror of the live kernel), and
      `VMLAUNCH`es. The `vmx_exit_trampoline` (naked) saves GPRs → `vmx_handle_exit`
      → `VMRESUME`. Compiled into KERNEL.BIN (`kernel_build.asm`); dead unless
      detect reports VMX usable AND boot calls `vmx_backend_arm` (it does not on
      the TCG CI boot, where VMX `#UD`s), so boot behavior is unchanged. A CI guard
      in `test_ghl_security_guards.ps1` proves it keeps compiling. **VMX `#UD`s on
      QEMU-TCG**, so VMLAUNCH success is verified only on an accel host per
      `scripts/test/run_vmx_accel.md`; tag flips to `tested-accel` after that run.
- [~] Trap CR0/CR4/CR3 writes + privileged insns that would disarm the floor.
      `tested-accel`-PENDING (real code; needs an accel host run)
      The CR-trap floor is armed in `vmx_program_controls`: the CR0/CR4
      GUEST/HOST masks mark CR0.WP|PG|PE and CR4.VMXE|SMEP|SMAP as monitor-owned,
      with read-shadows returning the kernel's real CRn so innocent reads stay
      transparent. A guest MOV-to-CRn touching a masked bit VM-exits (basic reason
      28) into `vmx_handle_exit`, which DROPS the change (fail-closed: a
      compromised ring-0 cannot clear WP / strip SMEP/SMAP / repoint CR3) and
      skips the instruction (`RIP += exit-instr-len`) before `VMRESUME`. The
      enforcement DECISION mirrors the `modeled` `mon_hal_vmx_vmcs.ghl` /
      `mon_hal.ghl` math. Real trap delivery needs the accel run above.

### AMD SVM (AMD-V)
- [~] Detect: `CPUID 8000_0001:ECX.SVM[2]`; enable `EFER.SVME`; NPT via VMCB. `modeled`
      (extends the existing fme/SME detect scaffold.) DETECT done:
      `mon_hal_svm_usable` checks CPUID + `VM_CR.SVMDIS` (firmware fuse-off); the
      `EFER.SVME` enable + NPT/VMCB bring-up remains the `tested-accel` half.
- [ ] VMCB for kernel-as-guest; identity **NPT**; `VMRUN`; `#VMEXIT` handler. `tested-tcg` → `tested-accel`
- [ ] Intercept CR/EFER writes + privileged insns. `tested-accel`

### ARM (AArch64) virtualization
- [x] Detect EL2 availability / VHE (`ID_AA64MMFR1_EL1.VH`). `modeled`
      `mon_hal_arm_el2_usable` (`ID_AA64PFR0_EL1.EL2` field) +
      `mon_hal_arm_vhe_present` (`ID_AA64MMFR1_EL1.VH` field).
- [ ] Run the kernel at EL1 under a monitor at EL2; identity **stage-2** translation
      (`VTTBR_EL2`/`VTCR_EL2`). `modeled` → `tested-accel`
- [ ] Trap via `HCR_EL2` (TVM/TRVM/privileged-access traps) the operations that
      would disable the floor. `tested-accel`

### RISC-V hypervisor extension
- [x] Detect the H-extension (`misa` H bit / SBI). `modeled`
      `mon_hal_riscv_h_usable` checks `misa` bit 7 (H = letter-index 7).
- [ ] Run the kernel in VS-mode under HS-mode monitor; identity **G-stage**
      (two-stage) translation (`hgatp`). `modeled` → `tested-accel`
- [ ] Trap supervisor CSR writes that would disarm the floor. `tested-accel`

### Cross-vendor
- [~] Carve the monitor + every Track 6 compartment OUT of the guest's
      second-stage map (not RO - **not present**); negative test per vendor: guest
      read of a compartment page → second-stage violation exit. `tested-accel`
      MODEL landed `tested-tcg`: `mon_hal_s2_map_perms` returns 0 (not-present)
      for any carve-out page and `mon_hal_s2_check` faults every access to it;
      eval asserts guest read/write of a monitor page → `MONHAL_S2_VIOLATION`.
      The real per-vendor second-stage violation EXIT still needs `tested-accel`.
- [~] EPT/NPT/stage-2/G-stage enforce W^X **independently of guest page tables**:
      guest clears WP + writes `.text` → second-stage violation, not a patch.
      `tested-accel` (per vendor) → `tested-hw`
      MODEL landed `tested-tcg`: identity map gives `.text` PRESENT|R|X (no W)
      and data PRESENT|R|W (no X); eval asserts a WRITE to `.text` and an EXECUTE
      of data both fault at the second stage regardless of the guest's perms.
      The real cleared-WP-then-write trap still needs `tested-accel`.

## G2 - IOMMU / device-DMA confinement (per vendor)

Install DMA-remapping from the per-artifact `allowed DMA buffers` manifest field
(Track 2); device DMA outside its grant faults. Genuinely impossible in software.

- [~] **Intel VT-d**: detect via ACPI DMAR; build root/context + 2nd-level page
      tables; per-device grants. `modeled` → `tested-hw`
      Presence-fold + per-device grant MATH landed (`mon_hal_iommu_usable` for
      DMAR, `mon_hal_iommu_translate` for grants); the live ACPI DMAR parse and
      the real root/context table writer remain `tested-hw`.
- [ ] **AMD-Vi (AMD IOMMU)**: detect via ACPI IVRS; device table + page tables. `modeled` → `tested-hw`
- [ ] **ARM SMMUv3**: detect via ACPI IORT; stream table + per-StreamID grants. `modeled` → `tested-hw`
- [ ] **RISC-V IOMMU**: detect + device-context grants. `modeled` → `tested-hw`
- [~] Route all four through the same `mon_hal.iommu_map`; the DMA-grant Track 6
      compartment (DMA-MON) is the only caller. `modeled` / `tested-tcg`
      `mon_hal_iommu_translate` is the single vendor-neutral remap the DMA-MON
      compartment calls; per-vendor presence DETECT is `mon_hal_iommu_usable`
      (DMAR/IVRS/IORT-SMMUv3/RV-node fold). The per-vendor table-format writers
      remain `tested-hw`.
- [~] Negative test per vendor: a driver guest programming a DMA descriptor
      outside its granted buffer → IOMMU fault. `tested-hw` (TCG cannot; KVM partial).
      MODEL landed `tested-tcg`: eval asserts a DMA below/past the grant →
      `FAULT_RANGE`, a wrong-direction access → `FAULT_PERM`, and a device with
      no grant → `FAULT_NOGRANT` (default-deny). The real device-issued DMA fault
      still needs `tested-hw`.

---

## Compatibility matrix (track per vendor; do not blur)

| Guarantee | Intel | AMD | ARM | RISC-V | no-virt HW / TCG |
|---|---|---|---|---|---|
| G1 root mode + identity 2nd-stage | VT-x+EPT | SVM+NPT | EL2 stage-2 | H-ext G-stage | floor-only (Track 6) |
| G1 trap floor-disable | VMCS CR-exit | VMCB intercept | HCR_EL2 | CSR trap | not enforceable in SW |
| G2 IOMMU DMA confinement | VT-d | AMD-Vi | SMMUv3 | RV IOMMU | **residual: undefended** |

"floor-only" / "residual: undefended" cells are the honest cost of running without
the hardware; STATUS.md §9 must name them.

## QEMU vs real-HW test boundary

TCG runs **none** of the root modes or IOMMUs. TCG-column results are `tested-tcg`
= logic-only (HAL dispatch, page-table math, manifest decode). VMLAUNCH/violations
need `tested-accel`; DMA faults need `tested-hw`. The verification entry point runs
the TCG-safe parts; the `-accel`/HW parts are a separate, explicitly-labeled run.

## Done definition for Track 5

- [ ] One `mon_hal` interface; ≥1 vendor back-end at `tested-accel`, the rest at
      `modeled`+`tested-tcg` with a clear path, all selectable at boot.
- [ ] G1: on every implemented vendor, the kernel runs as a guest and a compromised
      ring-0 cannot disable the Track 6 compartments (trap proven by negative test
      at `tested-accel`).
- [ ] G2: on every implemented vendor with an IOMMU, device DMA outside grant
      faults (`tested-hw`).
- [ ] On no-virt hardware and TCG the system is safe on the Track 6 floor; the two
      residuals (floor-disable, device DMA) are documented, not hidden.
- [ ] No capability claims a maturity tag it has not reached, per vendor.
