# GritOS - Project Status

_Last updated: 2026-05-25_

This document is the formal source of truth for project status,
milestones in flight, and what is parked vs. active. Memory files
under `~/.claude/projects/.../memory/` index into here; do not
duplicate detail there.

> **New here? Read `docs/TODO-INDEX.md` first.** It maps every TODO/spec/roadmap
> doc, says which is authoritative for what, snapshots current state, and lists
> the known false-alarm gotchas (e.g. the stray `worktrees/` guard noise). It
> exists so the doc sprawl doesn't trip you up.

---

## TL;DR

GritOS boots cleanly on the target hardware (Acer Nitro V16 AI,
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

## Milestones - done

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
| GritHL apps | Compiler + SVG2 subset (text, clip, gradients), 4 apps shipping | 2026-05-16 |
| GFX11 W2 H/I/J | SMU mailbox via NBIO SMN, GFXHUB ctx-0 PT enabled, CP GFX ring programmed (gated, real-HW verified) | 2026-05-26 |

Detail on individual fixes lives in `git log`; the audit sweep is
catalogued in `docs/audit-checklist.md`.

---

## Active focus: GPU-accelerated rendering

> **SUPERSEDED IN PART (2026-05-26).** This section predates the
> "widely-compatible interfaces only" decision (see MEMORY.md /
> `deprecated/README.md`). Per-vendor iGPU MMIO bring-up is discontinued, which
> **retires Tier 2 (DCN flip queue) and Tier 3 (GFX11)** below - they overlap
> the parked `deprecated/780M_IGPU/` work and are no longer an active goal.
> Only **Tier 1** survives, because it is vendor-neutral CPU/SMP work (SSE2/AVX2
> blit, dirty-rect, AP-core offload) that needs no per-vendor MMIO. The current
> project thrust is zero-asm + beyond-zero-trust security, not GPU rendering.

**Goal:** stop being CPU-bound for redraws. Today every visible
pixel is `rep movsq` from a backbuffer into the framebuffer, on the
BSP, on every flip.

Three tiers of work, ordered by effort and risk:

### Tier 1 - Faster CPU paths - **DONE (2026-06-09)**
- [x] SSE2 non-temporal copy (8×`movntdq`/128B) in `display_flip` and
  `display_flip_rect` (`src/kernel/drivers/display.asm`).
- [x] Dirty-rect tracking - `render_mark_dirty` + per-rect
  `display_flip_rect` flush (`src/kernel/gui/render.asm`), counters in
  `fbperf.asm`.
- [x] AP-core flip offload - `render_flush` snapshots the dirty list and
  submits `render_flip_job` to the SMP work queue (WQ_PRIO_HIGH, one job
  in flight, `workqueue_wait_timeout` drain so a dead AP can't freeze the
  GUI, inline fallback on single-core/queue-full). BSP returns to
  interactive work while the AP blits.

Tier 1 is the only surviving tier (see the supersession note above);
with it landed this section is closed.

### Tier 2 - DCN flip queue (4-8 weeks, medium risk)
- Page-flip via the display controller instead of CPU copy. Still
  the display block (not GFX), but takes the CPU off the critical
  path entirely.
- Requires programming a small subset of DCN HUBP / OPP / MPC
  registers and double-buffering the scanout pointer.
- DOES interact with DMUB for power transitions - Tier 2 is the
  most likely reason to un-park DMUB.

### Tier 3 - GFX11 (GC 11.5) bring-up (months, high risk)
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
  `DATA.IMG` - fat16 init-order bug or root-cache miss, unresolved.
- CW4 mailbox programmed at VRAM `0x64000000`/`0x64002000`, rings
  alive, but firmware in deep IPS - `cmd stat=00000005` (sent +
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
  not pursued - backlight on this panel appears to be DMUB-only.
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
Userland: window manager, taskbar, GritHL apps (.ghl)
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
sections - fix the threat model first, then build to it.

**Root of trust = measured boot + a kernel-held key, NOT silicon.** GritOS
targets UEFI-GOP / broadly-compatible hardware (see MEMORY.md: per-vendor
MMIO bring-up is discontinued). We do **not** assume a Secure Enclave, a TPM,
TEE/SEV memory encryption, fused per-device keys, or any hardware-anchored
PCR. The trust anchor is purely software: the kernel image as loaded into RAM,
self-measured into a kernel-owned digest (`crypto.ghl` -> `mb_digest`),
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
the BSP only - APs enter their dispatch loop with `CR0.WP=0` before protection
engages; per-AP WP-engage + SMP-safe (per-CPU/locked) windowing is the follow-up
before an all-core claim.

**A physical attacker with the boot medium is explicitly OUT of scope**
(unlike iOS / a TEE). Someone who can rewrite the ESP, swap KERNEL.BIN/APPS.BIN
on the USB stick, or attach a debugger to DRAM can already replace the whole
software stack - there is no silicon to stop them, and we do not pretend to.
A fused, hardware-verified boot chain is a non-goal for this project.

**Refinement (2026-06-04): a one-shot RAM-dump / snapshot attacker is now a
BEST-EFFORT in-scope goal** (Track 4, `docs/track4-ram-secure-erasure-todo.md`).
GritOS is moving to RAM-only / volatile operation with three layers:
  - **Software at-rest encryption** of stored DRAM (FS cache, app blobs, idle slot
    arenas, kernel secrets) under a per-boot ephemeral key - protects *stored*
    data; the only software residual is the on-die/cache state and the single
    granule currently decrypted for use.
  - **Hardware full-memory encryption when present** (Intel TME / AMD SME -
    detected + opportunistically used, no-op if absent): the memory controller
    makes *all* DRAM ciphertext at the DIMM, so even stored `.text` and page
    tables are AES-XTS ciphertext in a cold-boot / DMA-of-DRAM capture. This is
    detection + opportunistic enable of a standard architectural feature (like
    CET/SMAP/KPTI), not per-vendor MMIO bring-up, so it fits the portable stance;
    a *fused/anchored* boot chain remains the non-goal.
  - **Leak ≠ elevation** (the load-bearing claim): even if a dump is fully
    reversed (qrng seed, canary, `l3_slot_key[]`, blob key, files), elevation on a
    fresh boot must still fail for ≥8 independent reasons - per-boot ephemeral
    secrets, per-slot keys, heterogeneous syscall numbering, per-slot ASLR, CPI
    tags, cap-mask HMAC, W^X + nk-monitor, measured boot + blob MAC, KPTI/SMAP,
    anomaly+strike teardown, default-deny caps, shadow stack (Track 4 Part D).

**Part C honest caveats (do not overclaim FME).** Two limits bound any
hardware-full-memory-encryption (TME/SME) claim: (a) **QEMU TCG does not emulate
the memory-controller crypto** - guest DRAM stays plaintext on the host, so the
`pmemsave` test validates only the Part B *software* at-rest layer; a TME/SME
"active" row reported from a TCG boot proves the detect/report path, not that DRAM
is encrypted. Part C is verifiable only on real silicon (or KVM+SEV). (b) **TME/SME
defeat passive DRAM capture only** (cold-boot / physical-DIMM / DMA-of-DRAM); they
do NOT defend against code executing on the same CPU, since the memory controller
decrypts transparently for any on-die access - that attacker is the §1-§12 ring-3
containment / Part D (leak != elevation) job, not FME's.

This does NOT contradict the line above: a **sustained** attacker who reads DRAM
repeatedly or single-steps the CPU still wins (they read on-die plaintext), and is
out of scope. Earlier wording said this was "impossible in software" - that
overstated it: software protects *stored* data and hardware FME extends that to
all DRAM; only on-die transient state is irreducible. Every claim is bounded by
Track 4's `pmemsave` test and the Part D planted-leak negative test.

**Part A landed (2026-06-08): RAM-only / volatile execution.** GritOS runs from
RAM only - FS writes go to a session-only ramdisk (`ata_write_sectors` →
`ramdisk_intercept_write`; the `ramdisk_flush` write-back is an unimplemented
stub) and there is no swap / hibernation / scratch file, so nothing survives
power-off by construction. `src/kernel/grithlk/ram_volatile.ghl` (zero-asm)
scrubs the per-boot/per-slot secrets (`kernel_canary`, `l3_boot_nonce`,
`l3_slot_key[]`, code/stack ASLR slides, `l3_code_hash[]`, `slot_cap_hmac[]`,
TCP ISN key) and the live app-slot arenas on three teardown paths:
  - **shutdown** - serial `'w'` → `nx_volatile_wipe_halt` (scrub + wipe live
    arenas + `[WIPED]` + HLT; `pmemsave`-inspectable). `nx_volatile_shutdown` is
    the power-off variant.
  - **panic** - `kernel_panic_canary` / `kernel_panic_shadow` →
    `nx_volatile_panic_scrub` (secrets only) before the final HLT.
  - **tamper** - nk-monitor #PF, cap-mask HMAC mismatch and code-range mismatch
    all fail closed into `kernel_panic_canary`, so the panic hook covers them.
The arena sweep is page-table-walk-driven (only PRESENT pages, skipping the
non-present user-stack guard) and brackets its writes in the nk-monitor WP
window + `smap_open` so it can zero the read-only W^X code pages and the
user-PTE arena pages from ring 0. Verified in QEMU: a live app slot is wiped and
`[WIPED]` is reached with no fault. **Residual still plaintext at dump time**
(the irreducible live set, unchanged by Part A): the executing `.text`, live
page tables, the qrng seed in the now-RO image, and any secret currently in a
register/cache. Part B (at-rest encryption) and Part C (HW FME) are what shrink
that residual further; do not claim Part A erases it.

**Part B software-complete (2026-06-11): anti-forensic hardening.** Beyond the
per-boot ephemeral memory key (item 1) and first-scrubbed key region (item 3),
the four remaining software items landed in `ram_atrest.ghl` / `ram_volatile.ghl`
with boot self-tests (`[T4ST a=1 x=1 r=1]` on COM1): **item 5** point-of-use
scratch scrub (`nx_atrest_scrub_scratch`; the framebuffer/serial half holds by
construction - no secret is written there); **item 6** poison-freed-memory
(`nx_atrest_poison`, key-derived fill, **wired live** into `nx_volatile_wipe_arenas`
so swept slot pages carry ciphertext-like bytes, not zeros or stale plaintext);
**item 7** forward-secure rolling re-key (`nx_mem_key_rekey` + epoch; a dumped key
only opens its own epoch); **item 8** structure-fingerprint de-correlation (the
tweak-keyed cipher + poison make identical plaintext differ across regions).
Items 2/4 (encrypt-at-rest consumer wiring + mass secret-whitening) remain `[~]`
**by design** - a DRAM-resident mask gives ~zero gain against the one-shot dump,
so their real closure is Part C FME, not more software XOR. All three Track 4
test scripts pass (`test_track4_pmemsave.ps1`, `test_track4_planted_leak.ps1`,
`test_ghl_security_guards.ps1`).

**What IS in scope** (the things a software root of trust can and must
defend against):
  - A malicious or buggy **ring-3 app** escalating, escaping its slot, or
    forging kernel-checked authenticators (the bulk of §1-§8, §12).
  - **Accidental or casual tampering** of a loaded artifact (a corrupted
    APPS.BIN, a truncated blob, a build/packaging mistake, bit-rot on the
    medium) - detected, not cryptographically defeated.
  - **Runtime corruption** of an already-trusted artifact (a kernel-write
    bug mutating code/blob bytes after load) - caught by measured boot,
    code-range hashing, and the blob signature check below.

**Calibration - "good enough for a portable software root of trust", NOT
"matches a TEE".** Because there is no hardware anchor and no physical-attacker
requirement, primitives in §9/§10 are sized for *detection of tampering by a
non-physical adversary*, not for *cryptographic resistance against an attacker
who controls the medium*:
  - A **kernel-held-key MAC/HMAC** over an artifact is fully acceptable and is
    preferred over a public-key signature (Ed25519). The key lives in the
    kernel and the verifier is the kernel; there is no third party to convince
    and no offline-forgery requirement that a symmetric key fails to meet.
  - SHA-256 / HMAC-SHA256 is the active primitive for measured boot and the user-blob MAC. Remaining FNV-1a uses (`l3_slot_key`, code-range hashing, CPI/cap-mask tags) are narrower integrity fingerprints or short authenticators and remain labelled at their call sites.

Concretely, §9 "Sign the user blob" is satisfied by a **kernel-verified keyed
MAC** over `[app_blob_start, app_blob_end)` with a build-time key compiled
into the kernel, refusing to launch (fail closed) on mismatch - see
`src/kernel/grithlk/crypto.ghl` (`app_blob_verify_signature`) and TODO note in
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
- BAR0 MMIO must go through the explicit UC alias mapping - the GOP
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
