# NexusOS — Project Status

_Last updated: 2026-05-25_

This document is the formal source of truth for project status,
milestones in flight, and what is parked vs. active. Memory files
under `~/.claude/projects/.../memory/` index into here; do not
duplicate detail there.

---

## TL;DR

NexusOS boots cleanly on the target hardware (Acer Nitro V16 AI,
AMD Strix Point) under both BIOS and UEFI, runs a graphical desktop,
handles USB/I2C/PS-2 input, has working FAT16 ramdisk and
networking, and pushes pixels to the GOP framebuffer with WC-mapped
write-combining for ~10× faster flips than the original UC path.

The next focus area is **moving rendering off the CPU.** All current
drawing is CPU writes into the framebuffer. The DMUB/DCN firmware
side-quest (which would have unlocked backlight and panel power, but
*not* 3D acceleration) is parked at Phase 1; the work-in-progress
sits on `dev` and can be resumed if backlight becomes a priority.

---

## Milestones — done

| Area | What works | Landed |
|---|---|---|
| Boot (BIOS) | MBR → Stage2 → kernel @ 0x100000, unreal-mode bulk load | 2026-02-15 |
| Boot (UEFI) | BOOTX64.EFI → KERNEL.BIN, CR4/EFER sanitized, 1GB-page identity map to 512GB | 2026-02-15 |
| Display | GOP framebuffer scanout, backbuffer + flip, fonts, window manager | 2026-02 |
| Input (PS/2) | Keyboard with F1-F12 + key repeat, 5-button Intellimouse | 2026-02-23 |
| Input (USB) | xHCI HID, USB keyboard + mouse + multi-device, slot routing | 2026-02-24 |
| Input (I2C HID) | Touchpad with palm rejection, pinch-to-zoom, 3-finger swipe | 2026-02-23 |
| Filesystem | FAT16 ramdisk, real-HW DATA.IMG via UEFI loader shim | 2026-02 |
| Networking | RTL8156 USB 2.5GbE on real hardware | 2026-05-21 |
| FB performance | WC mapping via PAT slot 1, AP PAT propagated (~10× flips) | 2026-05-25 |
| NexusHL apps | Compiler + SVG2 subset (text, clip, gradients), 4 apps shipping | 2026-05-16 |
| GFX11 W2 H/I/J | SMU mailbox via NBIO SMN, GFXHUB ctx-0 PT enabled, CP GFX ring programmed (gated, real-HW verified) | 2026-05-26 |

Detail on individual fixes lives in `git log`; the audit sweep is
catalogued in `docs/audit-checklist.md`.

---

## Active focus: GPU-accelerated rendering

**Goal:** stop being CPU-bound for redraws. Today every visible
pixel is `rep movsq` from a backbuffer into the framebuffer, on the
BSP, on every flip.

Three tiers of work, ordered by effort and risk:

### Tier 1 — Faster CPU paths (1-3 weeks, low risk)
- SSE2/AVX2 memcpy for `display_flip` (currently scalar `movsq`).
- Dirty-rect tracking so we don't blit the whole screen each frame.
  Window manager already knows which windows moved.
- Offload `display_flip` to an AP core (SMP path is up; PAT already
  propagates). BSP returns to interactive work while the AP blits.

Expected: 2–5× on top of the WC win we already have. No new
firmware, no new microcontrollers, no PSP front-door.

### Tier 2 — DCN flip queue (4-8 weeks, medium risk)
- Page-flip via the display controller instead of CPU copy. Still
  the display block (not GFX), but takes the CPU off the critical
  path entirely.
- Requires programming a small subset of DCN HUBP / OPP / MPC
  registers and double-buffering the scanout pointer.
- DOES interact with DMUB for power transitions — Tier 2 is the
  most likely reason to un-park DMUB.

### Tier 3 — GFX11 (GC 11.5) bring-up (months, high risk)
- This is what "actual iGPU rendering" requires.
- Stack: PSP front-door → GMC/MMHUB page tables → MEC/RLC firmware
  load → CP ring queues (GFX, compute, SDMA) → MES scheduler → PM4
  packet emission → optional userspace stack.
- Not scoped or started. Cost is large; absent a userspace 3D layer
  we'd still be hand-writing PM4 packets to draw triangles.

**No decision yet on which tier to pursue first.** Tier 1 is the
clear next move unless the user has a specific reason to skip ahead.

---

## Parked

### DMUB / DCN firmware bring-up
**Where:** branch `dev`, latest commit `334e84f` (DMUB: ship
DCN3.5/3.1.4 firmware + read-only blob parser). Not merged to
master.

**State at park:**
- Phase 1 (read-only blob parse) shipped but reports `FW stat=01`
  ("not found") on hardware despite `DCN35DMC.BIN` being in
  `DATA.IMG` — fat16 init-order bug or root-cache miss, unresolved.
- CW4 mailbox programmed at VRAM `0x64000000`/`0x64002000`, rings
  alive, but firmware in deep IPS — `cmd stat=00000005` (sent +
  timeout, command never consumed). IPS-exit handshake via CW6
  shared_state not implemented.

**Why parked:** DMCUB is a power/PSR/backlight microcontroller. It
does not draw pixels. Even full Phase 2/3 success would not move
the project closer to "iGPU renders things." See
`memory/dmub_parked.md` for the resume plan.

**When to resume:** if backlight control, PSR, or panel hotplug
become priorities, or if Tier-2 DCN flip queue requires DMUB power
coordination.

### Battery / EC brightness probe
- Layout D AC verified, battery_init wiring fixed earlier in May.
- EC[0x2E] was identified as a candidate brightness register but
  not pursued — backlight on this panel appears to be DMUB-only.
- See `memory/amd_dcn_bar0_uc.md`.

---

## Architecture at a glance

```
Boot:    MBR (BIOS) | BOOTX64.EFI (UEFI)
            ↓
         KERNEL.BIN @ 0x100000
            ↓
Init:    GDT/IDT → paging → PIC/APIC → ACPI → SMP AP bring-up
            ↓
Drivers: GOP/VBE display → keyboard/mouse → xHCI/USB → I2C HID
         → PCI scan → ATA/ramdisk → FAT16 → networking (rtl8156)
            ↓
Userland: window manager, taskbar, NexusHL apps (.nxh)
```

- Kernel: 0x100000 (code+data), stack/IDT at 0x200000
- Page tables: 0x70000 (1GB pages on UEFI, 2MB on BIOS)
- Ramdisk / FAT16 cache: 0xD11000 (BIOS) / 0x1A11000 (UEFI)
- Framebuffer: GOP-supplied, mapped WC via PAT slot 1
- DMCUB FW buffer (parked): 0x7000000

Full source layout in `docs/source-layout.md`.

---

## Security threat model & hardware-anchoring scope (§9 boundary)

This section defines the scope boundary that the boot/firmware (§9) and
cryptographic-identity (§10) hardening in `docs/security_todo.md` are
evaluated against. It is the prerequisite decision for the rest of those
sections — fix the threat model first, then build to it.

**Root of trust = measured boot + a kernel-held key, NOT silicon.** NexusOS
targets UEFI-GOP / broadly-compatible hardware (see MEMORY.md: per-vendor
MMIO bring-up is discontinued). We do **not** assume a Secure Enclave, a TPM,
TEE/SEV memory encryption, fused per-device keys, or any hardware-anchored
PCR. The trust anchor is purely software: the kernel image as loaded into RAM,
self-measured into a kernel-owned chain (`measured_boot.asm` → `mb_digest`),
plus secrets the kernel derives and holds in kernel-only BSS/.rodata
(`kernel_canary`, `l3_slot_key[]`, the build-time blob-signing key). These
secrets never enter ring-3 memory, and after `kernel_lockdown_ro` the .text
/.rodata that holds compiled-in keys is mapped read-only.

**Nested-kernel page-table protection (portable, no CPU feature).** As of
2026-05-31 the page tables themselves are tamper-resistant from the kernel.
`src/kernel/core/nk_monitor.asm` is the Dautenhahn-style nested-kernel monitor:
after `kernel_lockdown_ro` engages `CR0.WP`, `nk_protect_page_tables` maps the
whole page-table region `[0x70000,0x83000)` read-only, so the ONLY code that can
mutate a mapping is the audited monitor window (`nk_pt_window_begin/end`, the
sole post-boot `CR0.WP` toggle site). Every runtime PTE writer brackets its edits
(`l3_apply_slot_isolation`/`l3_apply_wx_policy`/`l3_install_syscall_stack_pt`/
`sc_mprotect_wx`/`sc_wx_jit_alias`). This was chosen deliberately over hardware
CET (Intel-TGL+/AMD-Zen3+ only; QEMU TCG doesn't expose `shstk`) and over a
hypervisor (VT-x is again a CPU feature) so it runs on *every* x86-64 and under
TCG. A stray write / overflow / ROP chain that tries to clear W^X, make `.text`
writable, or remap a user slot as supervisor now `#PF`s. Verified positive
(`NKP+` marker, clean boot) and negative (`-ProbeNkPt` → deliberate un-bracketed
PML4 write faults, vec 0x0E errcode 3 @ CR2=0x70000). **Limitation:** enforced on
the BSP only — APs enter their dispatch loop with `CR0.WP=0` before protection
engages; per-AP WP-engage + SMP-safe (per-CPU/locked) windowing is the follow-up
before an all-core claim.

**A physical attacker with the boot medium is explicitly OUT of scope**
(unlike iOS / a TEE). Someone who can rewrite the ESP, swap KERNEL.BIN/APPS.BIN
on the USB stick, or attach a debugger to DRAM can already replace the whole
software stack — there is no silicon to stop them, and we do not pretend to.
A fused, hardware-verified boot chain is a non-goal for this project.

**What IS in scope** (the things a software root of trust can and must
defend against):
  - A malicious or buggy **ring-3 app** escalating, escaping its slot, or
    forging kernel-checked authenticators (the bulk of §1–§8, §12).
  - **Accidental or casual tampering** of a loaded artifact (a corrupted
    APPS.BIN, a truncated blob, a build/packaging mistake, bit-rot on the
    medium) — detected, not cryptographically defeated.
  - **Runtime corruption** of an already-trusted artifact (a kernel-write
    bug mutating code/blob bytes after load) — caught by measured boot,
    code-range hashing, and the blob signature check below.

**Calibration — "good enough for a portable software root of trust", NOT
"matches a TEE".** Because there is no hardware anchor and no physical-attacker
requirement, primitives in §9/§10 are sized for *detection of tampering by a
non-physical adversary*, not for *cryptographic resistance against an attacker
who controls the medium*:
  - A **kernel-held-key MAC/HMAC** over an artifact is fully acceptable and is
    preferred over a public-key signature (Ed25519). The key lives in the
    kernel and the verifier is the kernel; there is no third party to convince
    and no offline-forgery requirement that a symmetric key fails to meet.
  - The non-cryptographic **FNV-1a family** already used across the tree
    (`measured_boot.asm`, `l3_slot_key`, the CPI/cap-mask tags) is an
    acceptable documented stopgap for the *integrity-fingerprint* role. It
    detects accidental/casual tampering; it is NOT preimage- or
    collision-resistant against a determined adversary, and is labelled as
    such at every use. Swapping in SHA-256/real HMAC later is a primitive
    substitution behind the same call sites — the structure does not change.

Concretely, §9 "Sign the user blob" is satisfied by a **kernel-verified keyed
MAC** over `[app_blob_start, app_blob_end)` with a build-time key compiled
into the kernel, refusing to launch (fail closed) on mismatch — see
`measured_boot.asm` (`app_blob_verify_signature`) and TODO note in
`docs/security_todo.md` §9. Reaching for Ed25519 here would buy nothing the
threat model requires while adding a hard-to-audit NASM bignum.

---

## Open invariants worth not forgetting

- All async polling that runs every frame must be non-blocking state
  machines, not busy waits. The original I2C HID poll cost 100ms/frame
  before this rule was enforced.
- CPU-loop timeouts on real Strix Point hardware fire ~5000× faster
  than QEMU. All timeouts should be PIT-tick based, never raw `ecx`
  counters. See xHCI fixes 2026-02-24.
- BAR0 MMIO must go through the explicit UC alias mapping — the GOP
  framebuffer is WC, and a stray read from a neighboring WC page
  hangs the AMD DCN.
- USB device protocol=0 mice are relative, not absolute. Treat them
  as such even if the HID parser doesn't fire.
- The syscall dispatcher must reload `rax` from `[rsp + ALL_RAX]` after
  `SC_TRACE_APPEND`. The always-on §11 trace-ring macro leaves the user
  RIP in `rax` (its last store is the ring's forensic RIP anchor); the
  bounds check (`cmp rax, syscall_table_count`), the per-slot permutation
  and the `s` debug trace all key off `rax` as the syscall NUMBER. Without
  the reload every syscall number is replaced by its return RIP → always
  out-of-range → `.sc_invalid` → -1, so no app syscall ever dispatches and
  every app window paints blank/white. Fixed 2026-05-31 in
  `src/kernel/proc/syscall.asm` right after the `SC_TRACE_APPEND` call.

---

## How to rebuild

```powershell
# UEFI (primary target)
powershell -ExecutionPolicy Bypass -File scripts\build\build_uefi.ps1

# BIOS (still maintained for QEMU CI smoke)
powershell -ExecutionPolicy Bypass -File scripts\build\build_bios.ps1

# Source guards + UEFI smoke
powershell -ExecutionPolicy Bypass -File scripts\test\test_source_guards.ps1
powershell -ExecutionPolicy Bypass -File scripts\test\test_smoke_uefi.ps1
```

Boot USB / ESP is `E:\`. Build copies artifacts to
`E:\EFI\BOOT\{BOOTX64.EFI, KERNEL.BIN, APPS.BIN, DATA.IMG}` and
`E:\data.img`.
