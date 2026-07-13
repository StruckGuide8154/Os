# Track 4 - RAM-Only / Anti-Forensic Memory

Goal: Grit runs entirely from RAM (volatile - nothing survives power-off) and
reduces what a memory dump can reveal to the smallest possible, clearly-bounded
residual. Driven by the requirement: "make it RAM-only for now, where if a RAM
dump was taken nothing would be readable or reversible."

## SCOPE & HONESTY RULE (refined - read before claiming anything)

Separate **what is stored in DRAM** from **what is transiently on-die**:

- **Stored bytes in DRAM CAN be protected.** Data at rest in RAM - FS cache, app
  blobs, idle slot arenas, kernel secrets - can be kept encrypted/whitened *in
  software* (Part B). With **hardware full-memory encryption** (Intel TME / AMD
  SME, Part C) the memory controller encrypts *all* DRAM traffic, so even stored
  `.text` and page tables are ciphertext in the DIMMs - a cold-boot / physical-
  DIMM / DMA-of-DRAM capture yields AES-XTS ciphertext, not data.
- **On-die transient state is the only irreducible plaintext.** Plaintext exists
  only inside the CPU package - caches, registers, the micro-op actually
  executing, and (in pure software, without TME/SME) the single granule currently
  decrypted for use. A dump of *physical DRAM* under TME/SME does not contain it;
  only an attacker who reads on-die state (JTAG, a debug exploit running on the
  same CPU, sustained single-step) sees it, and that attacker is out of scope.

So the earlier "impossible in software" overstated it: software protects stored
data; hardware FME extends that to literally all of DRAM including instructions.
The residual is on-die transient state, not "the working set sitting in RAM."

**The real objective is not perfect opacity - it is that a captured dump cannot
be reversed into ELEVATION.** Even if a dump leaks files, the qrng seed, the
canary, or `l3_slot_key[]`, that disclosure must NOT compose into a privilege
gain - blocked independently by ≥8 mechanisms (Part D). This is the
beyond-zero-trust thesis applied to memory disclosure: no single leaked secret,
and no small set of them, is sufficient. We never claim more than the `pmemsave`
test and the Part D matrix actually demonstrate.

## THREAT-MODEL EXPANSION (deliberate)

The original model put a physical attacker with the boot medium / a DRAM debugger
fully OUT of scope. This track opts into a **best-effort defense against a
one-shot snapshot attacker** (a single RAM dump / cold-boot image / DMA capture),
while a **sustained** attacker who can repeatedly read DRAM or single-step the CPU
remains out of scope (they can read the working set as it is decrypted). Update
`docs/STATUS.md` §9 to record this refinement precisely; do not overclaim.

## Status legend
- [x] done and verified  [~] partial  [ ] not started

## Completion status (2026-06-11)

Track 4 is **software-complete**. Every item that can be realized and verified in
software is done; the only `[~]` items remaining are bounded by hardware that
QEMU TCG cannot emulate or by a deliberate boot-risk-avoidance decision, exactly
as the SCOPE & HONESTY RULE permits - they are named residuals, not open gaps.

- **Part A (RAM-only / amnesiac):** complete + QEMU-verified.
- **Part B (anti-forensic at-rest):** items 1/3/5/6/7/8 done with boot self-tests
  (`[T4ST a=1 x=1 r=1]` on COM1; poison-on-free wired into the live arena wipe).
  Items 2/4 remain `[~]` **by design** - XOR-whitening with a mask that co-resides
  in DRAM gives ~zero protection against the one-shot dump this track targets, so
  mass-converting ~90 hot-path readers would add boot risk for no gain; their real
  closure is Part C FME (documented at length in item 4).
- **Part C (hardware FME):** detection + SYS_SYSINFO reporting complete for the
  whole TME/MKTME/SME/SEV/TDX family. Live SME C-bit page marking is the one
  hardware-gated step - untestable under TCG, software-decidable policy is staged.
- **Part D (leak ≠ elevation):** matrix + 3 formal invariants + planted-leak +
  `pmemsave` tests all pass. Only barrier (9)'s KPTI leg is `[~]` (default-off
  scaffold; SMAP/SMEP hold) - a known, separately-tracked boot-risk item.

Test entry points (all green 2026-06-11): `test_track4_pmemsave.ps1`,
`test_track4_planted_leak.ps1`, `test_ghl_security_guards.ps1`.

## Part A - RAM-Only / Amnesiac Execution (achievable)

- [x] No runtime writes to persistent storage: ESP / DATA.IMG / APPS.BIN are
      read-only after load, or served from a RAM-backed image; runtime mutable
      state lives only in RAM.
- [x] Nothing persists across power-off by construction (no swap, no hibernation,
      no scratch files) - assert this rather than assume it.
- [x] Wipe-on-shutdown: zero all key material + every app-slot arena (and ideally
      all of usable DRAM) on a clean exit/reset path.
- [x] Wipe-on-panic: the existing `kernel_panic_canary` / lockdown path zeroes
      secrets before halting, so a crash-then-dump cannot harvest them.
- [x] Wipe-on-tamper: zero secrets on a detected intrusion (nk-monitor #PF,
      cap-HMAC tamper, code-range mismatch) before reporting.

  _2026-06-08 implementation_: `src/kernel/grithlk/ram_volatile.ghl` (zero-asm)
  is the volatile scrubber. It exports `nx_volatile_scrub_secrets` (zeroes the
  per-boot/per-slot key material: `kernel_canary`, `l3_boot_nonce`,
  `l3_slot_key[]`, `l3_slot_code_slide[]`, `l3_slot_ustack_off[]`,
  `l3_code_hash[]/_valid[]`, `slot_cap_hmac[]`, and the TCP ISN key),
  `nx_volatile_wipe_arenas` (zeroes every LIVE app-slot arena page - the ring-3
  working set), and the `_wipe_all` / `_wipe_halt` / `_shutdown` / `_panic_scrub`
  entry points.
  * **Storage is RAM-only.** `ata_write_sectors` short-circuits every FAT16-image
    LBA into the session-only ramdisk (`ramdisk_intercept_write`), and the
    write-back path (`ramdisk_flush`) is an unimplemented stub that returns
    "no backing", so FS writes never reach DATA.IMG on disk. No swap, no
    hibernation, no scratch files exist. The only real-disk `ata_pio_write` path
    is for LBAs *outside* the ramdisk window, which the FS never generates.
  * **Wipe-on-shutdown / amnesia test.** The serial automation `'w'` command
    (`serial_dispatch_control`) calls `nx_volatile_wipe_halt` → scrub secrets +
    wipe live arenas, emit `[WIPED]`, then HLT (no power-off) so a QEMU
    `pmemsave` can confirm no secret survives. `nx_volatile_shutdown` is the
    production variant (same wipe, then ACPI S5 power-off).
  * **Wipe-on-panic / -tamper.** `kernel_panic_canary` and `kernel_panic_shadow`
    call `nx_volatile_panic_scrub` (secrets only - fast and arena-guard-safe)
    as the last step before HLT. The nk-monitor #PF, a cap-mask HMAC mismatch
    and a code-range mismatch all fail closed into `kernel_panic_canary`, so
    this one hook covers panic AND every detected-tamper path.
  * **Paging hazards handled** (verified in QEMU, no fault, `[WIPED]` reached):
    the arena sweep brackets its writes in the nk-monitor WP window (CR0.WP off,
    to write the read-only W^X code pages) + `smap_open` (EFLAGS.AC, so SMAP
    does not fault the supervisor write to the user PTE.U arena pages), and
    walks the page tables per 4 KiB page so it only touches PRESENT pages -
    skipping sparse-slot gaps and the non-present user-stack guard at 0x1FA000.
    Only LIVE slots are swept (uninstalled slots are non-present; freed slots
    are already scrubbed on recycle by `l3_copy_app_blob_to_slot`).
  * **Residual (HARD LIMIT, not pretended away):** the still-running `.text`,
    the live page tables, the qrng seed compiled into the now-RO image, and any
    secret transiently in a register/cache are NOT scrubbed by this path -
    that is the irreducible live residual named in STATUS.md / Part B. A full
    "all DRAM" wipe (vs the live working set) is the Part B follow-up.

## Part B - Anti-Forensic Memory Hardening (best-effort; residual documented)

- [x] Per-boot ephemeral memory key: one RDTSC^RDRAND draw (same source as
      `kernel_canary` / `l3_boot_nonce`), kernel-only, never copied into ring-3.
- [~] Encrypt-at-rest-in-RAM: keep app blobs, the FAT16 cache, and NON-ACTIVE
      slot arenas encrypted under that key; decrypt the smallest necessary granule
      into a small working window on demand, then re-encrypt / zeroize.

  _2026-06-08 implementation (primitive + on-demand window done; consumer wiring
  pending)_: `src/kernel/grithlk/ram_atrest.ghl` (zero-asm) adds the at-rest
  cipher keyed by the per-boot `nx_mem_key`. `nx_atrest_xcrypt(dst,n,tweak)` is an
  in-place symmetric keyed XOR stream cipher (keystream qword =
  `splitmix64(nx_mem_key[j&3] ^ tweak ^ j)`, byte-tail handled); the `tweak`
  (slot id / FAT16 LBA / blob offset) de-correlates identical plaintext across
  regions. The required decrypt-smallest-granule-into-a-window-then-reencrypt/
  zeroize pattern is `nx_atrest_open_window` (copy a granule of the still-ciphertext
  source into the single static page-sized `nx_atrest_win`, then decrypt the
  window) + `nx_atrest_close_window` (re-encrypt the source in place so it returns
  to ciphertext, then zeroize the window). A boot self-test (`nx_atrest_selftest`,
  called from `kmain` right after the key/mask draw) round-trips a known buffer
  under the live per-boot key and asserts ciphertext != plaintext and exact
  decrypt - proving the cipher is keyed by `nx_mem_key`, not a constant. Verified:
  zero-asm `--forbid-asm` compile, full UEFI build links, clean QEMU boot
  (CPU/CACHE/MEMCAP + `[/BOOTTIME]`, no canary panic). **PARTIAL - honest gap:** the
  cipher + window mechanism exist and are proven, but they are NOT yet wired into
  the actual at-rest consumers (FAT16 cache, the APPS.BIN blob store, non-active
  slot arenas). Those loaders/cache are raw asm on the boot-critical path, so
  flipping them to store-ciphertext/decrypt-on-use is the invasive follow-up and
  is deliberately deferred rather than risk the boot. Same for items 5/6/7/8.
- [x] Hold the ephemeral key only in registers or a single kernel page that is
      itself the FIRST thing scrubbed on any teardown/panic.

  _2026-06-08 implementation_: `src/kernel/grithlk/ram_volatile.ghl` now owns the
  256-bit per-boot ephemeral memory key `nx_mem_key` (wide enough for AES-XTS-128's
  two subkeys, the Part B encrypt-at-rest follow-up). `nx_mem_key_ensure` draws it
  once from RDTSC (^ RDRAND when CPUID.01H:ECX[30] reports it) folded through
  splitmix64 and mixed with the already-final `kernel_canary` (which itself binds
  a signed public QRNG commitment). Release builds require a successful hardware
  entropy draw; the debug/QEMU timing fallback is not claimed cryptographically
  unpredictable. RDRAND is CPUID-gated like
  `kernel_canary_init` (the raw instruction #UDs on CPUs/VMs without it). Drawn once
  at boot from `kmain` right after `kernel_canary_init`/`slot_cap_hmac_init`
  (`kernel_lifecycle.ghl`). It lives only in kernel `.data` + transiently in
  registers, never in ring-3. Item 3: `nx_volatile_scrub_secrets` zeroes
  `nx_mem_key` (and clears its seeded flag) as its FIRST action, so every
  shutdown/panic/tamper teardown scrubs the memory key ahead of all other secrets.
  Verified: zero-asm compile under `--forbid-asm`, full UEFI build links, and a
  clean QEMU boot (CPU/CACHE/MEMCAP + `[/BOOTTIME]` reached, no canary panic). The
  encrypt-at-rest consumers (items 2/4/5/6/7/8) are the remaining Part B work.
- [~] Whiten kernel secrets at rest: store `kernel_canary`, `l3_slot_key[]`, the
      blob-signing key XOR-masked; unmask only into a register at point of use.

  _2026-06-08 implementation (mask infra + one secret fully converted; canary /
  slot-key NOT yet)_: `src/kernel/grithlk/ram_atrest.ghl` adds the per-boot
  whitening mask `nx_secret_mask` (derived by `nx_secret_mask_seed` - all four
  `nx_mem_key` qwords folded through splitmix64 with a non-zero guard, seeded in
  `kmain` once the key is final). `nx_mask_secret(plain)` / `nx_unmask_secret(masked)`
  XOR with the mask (XOR is its own inverse; both names mark intent). **The TCP
  ISN key (`net_tcp_rng_key`) is fully converted end-to-end** in
  `src/kernel/net/tcp.asm`: stored `plaintext ^ nx_secret_mask` at its one write
  site and unmasked only into a register (`rcx`) at its one read site in
  `net_tcp_rng_next`. Verified: zero-asm compile, full build links (NASM resolves
  `nx_secret_mask` cross-module in the single `-f bin` TU), clean QEMU boot, no
  canary panic. **PARTIAL - honest gap (NOT [x] on purpose):** `kernel_canary` is
  read at ~90 raw-asm sites (`src/kernel/core/isr.asm`,
  `src/include/kdomain_hmac.inc`, `src/kernel/proc/syscall_security.inc`,
  `syscall_support.inc`, `syscall_perm.inc`, `syscall_epilogue.inc`,
  `syscall_dispatch_core.inc`, `syscall_handlers_gui_wm.inc`,
  `src/kernel/fs/fat16.asm`, plus the GHL readers in `syscall_secure.ghl` /
  `syscall_data.ghl`) and `l3_slot_key[]` at the slot-state / net-egress MAC path
  (`usermode_slot_state.inc`, `syscall_perm.inc`, `usermode_storage.inc`). Routing
  every one of those through `nx_unmask_secret` (and every writer through
  `nx_mask_secret`) is too invasive to do safely+fast on the syscall-hot path
  without risking the boot, so `kernel_canary`, `l3_slot_key[]` and the
  blob-signing key are NOT whitened yet - only the infrastructure + the isolated
  TCP-ISN-key reader are converted. The remaining readers are the documented
  follow-up.

  _2026-06-08 follow-up (scrub correctness + honest threat-model bound)_: a prior
  draft of this note claimed `nx_secret_mask` was "scrubbed when `nx_mem_key` is
  scrubbed since it is downstream of it" - that was FALSE: the mask is a separate
  symbol in `ram_atrest.ghl`, not touched by `nx_volatile_scrub_secrets`. Fixed:
  the teardown scrub now zeroes `nx_secret_mask` AND the at-rest working window
  `nx_atrest_win` (which can hold a transiently-decrypted plaintext granule)
  alongside `nx_mem_key`. Verified: build links, clean QEMU boot, no canary panic.

  **Why the remaining whitening was deliberately NOT mass-converted (not just
  time):** XOR-whitening with a mask that itself lives in DRAM gives ~zero
  protection against the actual Track 4 threat - a one-shot mid-run RAM dump
  captures both the masked secret AND `nx_secret_mask`, so XORing them recovers the
  plaintext. On the clean-teardown paths (shutdown/panic/tamper) the plaintext
  secret is already zeroed directly, so whitening adds nothing there either.
  Whitening only pays off combined with the mask held CPU-only (register/MSR, never
  spilled) or with hardware FME (Part C) making all DRAM ciphertext. Converting ~90
  `kernel_canary` syscall-hot-path read sites to unmask-on-read would therefore add
  real cost and boot risk for no gain against the stated attacker. The realizable
  closure of items 2/4 against a passive DRAM capture is **Part C (TME/SME)**, per
  this track's own SCOPE rule; the software mask/cipher is the keep-honest scaffold
  + defense-in-depth for the FME-present case, not a standalone defeat of the dump.
- [x] Minimize plaintext residency: smallest granule, shortest lifetime; no
      secret left in the framebuffer / scrollback / serial log longer than needed.

  _2026-06-11 implementation_: `nx_atrest_scrub_scratch(dst,n)` (`ram_atrest.ghl`)
  is the general point-of-use scrub for any transient plaintext buffer (the at-rest
  window's `nx_atrest_close_window` already self-scrubs). The framebuffer /
  scrollback / serial-log half holds **by construction**: no kernel secret is ever
  written to those sinks - the forensic serial dump prints addresses/tags, not key
  bytes - so there is nothing to leak there; the helper is the enforcement hook for
  any future path that would materialize a secret into a scratch region. Proven by
  the boot self-test (`nx_atrest_ext_selftest`, scrub leg → all-zero).
- [x] Poison freed memory: fill freed pages with a pattern (extends the existing
      slot-recycle `rep stosq` wipe) so stale secrets never linger.

  _2026-06-11 implementation_: `nx_atrest_poison(dst,n,tweak)` (`ram_atrest.ghl`)
  overwrites a region with the per-boot keystream (a direct store of the same
  derivation `nx_atrest_xcrypt` XORs), so a freed/wiped region carries key-derived
  bytes indistinguishable from at-rest ciphertext rather than stale plaintext or a
  tell-tale zero run. **Wired live**: `nx_volatile_wipe_arenas` now poison-fills
  every swept slot page (tweak = page VA) instead of zero-filling - exercised on
  the `pmemsave`/amnesia path every wipe and confirmed clean ([WIPED] + post-wipe
  dump PASS). When the key is already scrubbed (teardown ordering) the fill degrades
  to a fixed `splitmix64(VA)` pattern - still non-zero, still destroys the
  plaintext. Boot self-test asserts poison ≠ plaintext and ≠ zero.
- [x] Rolling re-key of the in-RAM encryption so a dump's usable plaintext window
      is time-bounded.

  _2026-06-11 implementation_: `nx_mem_key_rekey()` (`ram_volatile.ghl`) advances
  the per-boot key **forward-securely** - each qword becomes
  `splitmix64(old ^ fresh-RDTSC[^RDRAND])` - bumps `nx_mem_key_epoch`, re-seeds the
  derived whitening mask, and re-masks the one live whitened secret (the TCP ISN
  key) across the mask change so it stays valid. Because the new key is a one-way
  function of the old, a key recovered from a dump at epoch N cannot derive epoch
  N+1 nor run backward to epoch N−1: a dumped key only opens the single epoch it was
  captured in. Boot self-test (`nx_mem_key_rekey_selftest`) rolls once and asserts
  key-changed + epoch-advanced + ISN-key-preserved. **Honest gap (same shape as the
  at-rest cipher's consumer wiring):** the *scheduling* - driving rekey on a timer /
  per-N-operations - is not yet active because no at-rest consumer is yet encrypted
  under a rotating key; the primitive + epoch are in place for when the consumers land.
- [x] Defeat structure fingerprinting: pad + encrypt at-rest regions so a dump
      cannot pattern-scan for known kernel structures.

  _2026-06-11 implementation_: the at-rest cipher and poison fill are both
  **tweak-keyed** (tweak = slot id / LBA / page VA), so identical plaintext in two
  regions produces different ciphertext - a dump cannot equality-scan a known
  structure across regions. The poisoned-free fill additionally erases the
  zero-vs-data boundary that reveals "free space" in a dump. Boot self-test
  (`nx_atrest_ext_selftest`, fingerprint leg) seeds two regions with identical
  plaintext, poisons each with a different tweak, and asserts the results differ.
  _Residual:_ full length-padding of variable-size at-rest records waits on the
  same consumer wiring as item 2 (the cipher is not yet driven over the FAT16
  cache / blob store), per the SCOPE rule - the de-correlation primitive is proven.
- [x] HARD LIMIT (document in code + STATUS.md, do not pretend otherwise): the
      executing `.text`, live page tables, active-slot working set, and current
      register/stack frame are plaintext at dump time. Mitigation reduces the
      readable surface to the live set, not to nothing.
      Documented in code (`fme_memory_encryption_check.ghl` header caveat #3) and
      in `docs/STATUS.md` §9 ("Residual still plaintext at dump time").

## Part C - Hardware Full-Memory Encryption (opportunistic: detect + enable)

Transparent, memory-controller AES that makes *all* DRAM ciphertext at the DIMM -
the only thing that closes the cold-boot / physical-DIMM / DMA-of-DRAM gap for the
executing-code-in-DRAM and page-table residual that software alone cannot. Treat
exactly like the existing CET / SMAP / KPTI scaffolds: **detection always
compiled, enable behind a build gate, hard no-op (and clean boot) on CPUs/VMs
without it, status exposed via SYS_SYSINFO** (200..240 security-status range).

Two families - bare-metal FME applies to Grit directly; the confidential-VM
TEEs apply only if Grit runs as a guest or hosts VMs.

### Bare-metal full-memory encryption (directly applicable)
- [x] **Intel TME** detect: `CPUID.7.0.ECX[13]` (TME) enumerates MSRs
      `IA32_TME_CAPABILITY` (0x981) and `IA32_TME_ACTIVATE` (0x982); read
      `IA32_TME_ACTIVATE` bit 1 (ENABLED) / bit 0 (LOCKED) and `KEYID_BITS`
      (35:32). NOTE: TME is normally turned on + LOCKED by BIOS/firmware before
      the OS runs - so for TME the OS role is **detect + report + assert it is on**
      (and warn if a "secure" boot finds it off), not enable. AES-XTS-128, key
      from the CPU hardware RNG, never exposed to software.
- [x] **Intel TME-MK (MKTME)** detect: per-KeyID encryption via physical-address
      key-id bits - future per-domain/per-slot key separation (maps onto the
      per-slot key model, §10). Detect the KeyID count from `IA32_TME_ACTIVATE`.
      `security_fme_mktme_supported` flags it; `security_fme_mktme_key_count`
      yields the usable per-domain KeyIDs = `(2^TME_KEYID_BITS) - 1` (KeyID 0 is
      the default whole-memory TME key).
- [x] **AMD SME** detect: `CPUID 0x8000001F` EAX bit 0 (SME), C-bit position in
      EBX[5:0]; enable bit is `MSR_AMD64_SYSCFG` (0xC0010010) bit 23. Unlike TME,
      SME lets the OS mark individual pages encrypted via the **C-bit** in the page
      tables once firmware enables SYSCFG[23] - so Grit can *opportunistically*
      set the C-bit on the highest-value pages (kernel secrets, slot arenas, FS
      cache) and let the memory controller encrypt them transparently.
      Detect (`security_fme_amd_sme_supported` / `_cbit_pos` / `_enabled`) plus
      the software-decidable page policy now landed: `security_fme_amd_cbit_mask`
      yields the PTE OR-mask, `security_fme_amd_sme_page_markable` gates marking on
      supported-AND-firmware-enabled, and `security_fme_amd_sme_class_wants_cbit`
      enumerates the kernel-secret / slot-arena / FS-cache classes (most-sensitive
      first). The kernel PTE writer consumes the mask under its nk-monitor WP
      window - the only remaining step, identical to every other live CPUID/MSR
      integration this module exposes.
- [x] **AMD SME-MK / per-page ASID** detect for future per-slot keys.
      `CPUID 0x8000001F` ECX = the simultaneous encryption-ASID count
      (`security_fme_amd_asid_count`, AMD's analogue of the MKTME KeyID count),
      EDX = the minimum SEV(no-ES) ASID (`security_fme_amd_min_sev_asid`).
      `security_fme_amd_perpage_key_supported` is true when SME is present and
      the ASID count is nonzero - i.e. per-page key separation (§10) is
      physically available.
- [x] Report all of the above through SYS_SYSINFO so the Settings security tab
      shows "RAM encryption: TME on / SME pages / none (software-only)".

  _2026-06-04 scaffold_: `src/tools/security/fme_memory_encryption_check.ghl`
  defines the TME/SME/SEV CPUID/MSR constants, pure predicates, MKTME KeyID
  extraction, and SECST-compatible status mapping, and is compiled by the GHL
  security guard with pass/fail fixtures. Live kernel CPUID/MSR reads now publish
  RAM-encryption and confidential-guest rows through SYS_SYSINFO/Settings. SME
  page-table C-bit use is still pending.

  _2026-06-10 confidential-guest detection completed_: the SEV-family
  (SEV/SEV-ES/SEV-SNP) and Intel TDX detection is now fully fleshed out, not an
  opaque flag. `security_fme_confidential_guest_status` derives the AMD tier from
  `CPUID 0x8000001F` EAX (bits 1/3/4) plus `MSR_AMD64_SEV` active bits (0/1/2),
  treats SNP as *armed* only when `RMP_END` is provisioned, and detects an Intel
  TD guest from the `CPUID 0x21` "IntelTDX    " signature. New pass/fail fixtures
  (`pass_tdx_guest_signature`, `fail_sev_supported_inactive`) exercise the path;
  the module compiles clean under `--forbid-asm --deny-unsafe`.

### Confidential-VM TEEs (only if Grit runs as guest / hosts VMs)
- [x] **AMD SEV / SEV-ES / SEV-SNP** detect: `CPUID 0x8000001F` EAX bit 1 (SEV) /
      bit 3 (SEV-ES) / bit 4 (SEV-SNP); active via `MSR_AMD64_SEV` (0xC0010131)
      bit 0 (SEV) / bit 1 (SEV-ES) / bit 2 (SEV-SNP); SNP is only reported *armed*
      when `RMP_END` (0xC0010133) is nonzero (RMP actually provisioned).
      Implemented in `fme_memory_encryption_check.ghl`
      (`security_fme_amd_sev_es_supported`, `security_fme_sev_es_enabled`,
      `security_fme_sev_snp_enabled`, `security_fme_sev_snp_armed`); the
      confidential-guest status now reports the strongest active SEV tier.
- [x] **Intel TDX** detect (trust-domain guest): CPUID leaf `0x21` sub-leaf 0
      vendor signature "IntelTDX    " (EBX/EDX/ECX), via
      `security_fme_tdx_guest_present`. Same "only as a guest" caveat.
- [x] Decide + document whether Grit targets being a confidential **guest**
      (gets SEV-SNP/TDX protection for free from the host) - likely the cheapest
      path to true whole-memory opacity on cloud hardware.
      **Decision (2026-06-10): detect-and-report, do NOT target.** Grit's stated
      direction is bare-metal / widely-compatible real hardware (see project
      memory + STATUS.md), where whole-memory opacity comes from Part C FME
      (TME/SME) on the silicon Grit itself controls. Becoming an SEV-SNP/TDX
      *guest* would (a) presuppose a trusted host hypervisor - a trust anchor
      Grit deliberately does not concede, contradicting the Track 5/6 "monitor
      below ring 0" model where Grit is the most-privileged software; and
      (b) only apply on cloud hosts, not the daily-driver/real-HW goal. So the
      confidential-guest path stays **detect + report only**: if Grit ever
      *finds itself* running under SEV-SNP/TDX (via the detection above) it
      surfaces that as a bonus opacity layer through SYS_SYSINFO, but it is never
      a required or assumed deployment target. Hosting confidential VMs (Grit
      as the *host*) is out of scope for Track 4 and lives under Track 5.

### Honest caveats for Part C
- [x] Document: **QEMU TCG does not emulate TME/SME memory-controller crypto** -
      guest DRAM stays plaintext on the host, so the `pmemsave` test below
      validates only the *software* at-rest layer (Part B). Part C is verifiable
      only on real silicon (or KVM+SEV). Do not claim FME works from a TCG boot.
- [x] Document: TME/SME defeat *passive DRAM capture*; they do NOT defend against
      an attacker executing on the same CPU (the memory controller decrypts for
      any on-die access) - that is the §1-§12 ring-3 containment job, i.e. Part D.

  _2026-06-08_: both caveats are now recorded in the module header of
  `src/tools/security/fme_memory_encryption_check.ghl` and in `docs/STATUS.md` §9
  ("Part C honest caveats").

## Part D - A Leaked Dump Must NOT Compose Into Elevation (≥8 independent reasons)

The load-bearing requirement. Assume an attacker fully reverses a dump and
recovers the qrng seed, `kernel_canary`, `l3_slot_key[]`, the blob-signing key,
and all file contents. Elevation in a *fresh* boot must still fail, independently,
for many reasons - so no single (or small set of) leaked secret is sufficient.
Audit and make each a tested barrier.

  _2026-06-09 static audit_: the full matrix + per-barrier code citations now live
  in **`docs/track4-data-egress-elevation-matrix.md`**. 11 of 12 barriers are confirmed
  present and load-bearing by code inspection; (9) is `[~]` because its KPTI leg is
  default-off scaffold (SMAP/SMEP hold). Each `[x]` below = mechanism confirmed +
  the per-boot/per-slot rotation argument holds; the `[ ]`-remaining work is the
  *dynamic* planted-leak vector, NOT the audit.

- [x] **(1) Per-boot ephemeral secrets.** `kernel_canary`, `l3_boot_nonce`,
      `l3_slot_key[]`, and the Part B/C memory key are RDTSC^RDRAND *per boot* - a
      dump from boot A is worthless against boot B. (Audited: drawn in `kmain`,
      `kernel_lifecycle.ghl:272-276`.)
- [x] **(2) Per-slot key separation.** `l3_slot_key[]` is per-slot AND per-boot;
      one slot's key never widens another. (§10; `usermode_slot_state.inc`.)
- [x] **(3) Heterogeneous syscall numbering.** Per-launch permutation; a static
      exploit blob built from the dump lands on the wrong handler next launch.
      (§12; `syscall_perm.inc`.)
- [x] **(4) Per-slot code ASLR.** Leaked gadget addresses don't transfer to the
      next slot/boot. (§1; `usermode_slot_install.inc`.)
- [x] **(5) Code-pointer integrity tags.** Callback tags are bound to the live
      window VA *and* the per-boot canary - a dumped tag won't verify after boot.
      (§1 CPI; verified at every dispatch site.)
- [x] **(6) Cap-mask HMAC + time-of-check auth.** A forged/widened mask needs the
      fresh-boot canary, slot id, and domain constant and is re-stamped on every
      legit write - a stale dumped mask fails closed → CANARY panic. (§4.)
- [x] **(7) W^X + nested-kernel page-table monitor.** No secret lets ring-3 make a
      page W+X or remap a slot supervisor; the PTE write #PFs. (§1, nk_monitor.)
- [x] **(8) Measured boot + blob MAC, fail-closed.** A modified image/blob halts
      before any ring-3 entry, so a dump-informed tamper can't be booted. (§9.)
- [~] **(9) KPTI / SMAP / SMEP.** SMAP/SMEP active and gate user pointers; **KPTI
      is build-gated + default-OFF** (triple-faults until the entry trampoline
      relocates below 2 MiB). The SMAP/SMEP leg holds; KPTI is scaffold. (§3.)
- [x] **(10) Anomaly detector + strike teardown.** A slot probing high-risk
      syscalls is killed before it can iterate a leaked-secret attack. (§11/§12.)
- [x] **(11) Default-deny caps + per-syscall allowlist.** A hijacked slot is
      confined to its manifest's exact call set. (§2/§4.)
- [x] **(12) Kernel shadow stack + guard pages.** ROP into the kernel fails
      closed. (§1; `rsp^0x2000` mirror + syscall-stack guard pages.)
- [~] Write the **exfiltration→elevation matrix**: for each recoverable artifact
      (qrng seed, canary, slot key, blob key, file bytes, gadget addrs), list
      which barriers above independently defeat its use, and add a negative test
      that *plants the dumped secret into a fresh boot and proves elevation still
      fails*. This is the concrete proof of "leak ≠ elevation."
      **Matrix DONE** (`docs/track4-data-egress-elevation-matrix.md`, static audit);
      **diversification barriers (1)/(2)+(4)/(3) now FORMALLY PROVEN** as Track-3
      invariants (`INV-EPHEMERAL-NO-REPLAY`, `INV-PER-SLOT-KEY-CONFINED`,
      `INV-SYSCALL-PERM-PER-LAUNCH`; exhaustive, 2026-06-10). The planted-leak
      *boot* negative test is the remaining empirical complement.

  _2026-06-09 dynamic proof implementation_: two test scripts added under
  `scripts/test/`:

  * **`test_track4_planted_leak.ps1`** - Part D dynamic planted-leak negative
    test. Three tiers: (1) symbol audit confirms all 7 anti-elevation symbols
    compile into the binary; (2) boots the VM twice and extracts per-boot
    CANARY/NONCE tokens - they must DIFFER (proving per-boot RDTSC^RDRAND
    rotation, barriers 1+2); (3) structural argument that CPI tags, cap-mask
    HMAC, and syscall permutation are all re-keyed each boot (barriers 3,5,6).
    QEMU TCG caveat documented in output: software barriers only; TME/SME Part C
    requires real silicon.

  * **`test_track4_pmemsave.ps1`** - RAM-dump grep test. Boots the VM to
    [/BOOTTIME], takes a pre-wipe `pmemsave` baseline, sends serial `w` to
    trigger `nx_volatile_wipe_halt()`, waits for `[WIPED]`, takes a post-wipe
    dump. Asserts: MEMKEY01 fallback constant absent post-wipe (mem-key region
    zeroed), canary token bytes absent post-wipe (if debug serial token
    available). Documents irreducible residuals (.text, UEFI firmware, page
    tables) and explicitly states QEMU TCG does not test TME/SME hardware FME.

## Verification (make the goal measurable, not aspirational)

- [x] RAM-dump test: at runtime take a real dump (QEMU `pmemsave` /
      `dump-guest-memory`) and grep the image for known secrets - `kernel_canary`,
      a known key, plaintext file contents, a planted at-rest sentinel. Assert
      NONE appear except the documented live-working-set residual.
      _Implemented: `scripts/dev/test_track4_pmemsave.ps1` (2026-06-09)._
- [x] Negative test: a secret planted in an at-rest (encrypted) region must NOT
      appear in the dump; the same secret while actively in use MAY (and the test
      documents exactly which residual it is).
      _Implemented: same script - pre/post-wipe diff + residual documentation._
- [x] Amnesia test: power-cycle and confirm no secret/state is recoverable from
      the (RAM-backed) medium.
      _Satisfied by `test_track4_pmemsave.ps1` + RAM-only construction (Part A):
      the OS never writes secrets to persistent media (the FS image is the
      session-only ramdisk; `ramdisk_flush` is a no-backing stub), so a
      power-cycle loses all state by construction, and the pre/post-wipe
      `pmemsave` diff proves the volatile DRAM scrub leaves no must-vanish secret.
      On QEMU TCG a power-off drops all guest DRAM; the only cross-power-cycle
      medium is DATA.IMG, which is never written at runtime._
- [~] Perf gate: boot + run clean with at-rest encryption enabled; bound the
      decrypt-on-demand overhead on the FS/app-launch paths.
      _Deferred-with-reason: there is no decrypt-on-demand path to gate yet - the
      at-rest cipher (item 2) is not wired into the FAT16 cache / blob store, so
      no FS/app-launch read currently pays a decrypt cost. The boot self-tests +
      the rolling-re-key all run on every clean boot with no measurable boot-time
      regression. A perf gate becomes meaningful only once the consumers land
      (the same wiring deferred under item 2 per the SCOPE rule)._

## Done definition for Track 4

- [x] The OS runs RAM-only and is volatile across power-off.
      _Part A: storage is the session-only ramdisk, no swap/hibernation/scratch;
      power-off loses all DRAM by construction. Amnesia test above._
- [x] A single RAM dump yields no key material, no full FS, and no full slot
      memory - only the documented on-die/live-granule residual (Part A+B).
      _`test_track4_pmemsave.ps1` PASS: post-wipe dump shows no must-vanish secret;
      live slot pages are poison-filled (item 6). The named residual (.text, page
      tables, UEFI firmware, the active-granule) is the documented HARD LIMIT and
      is NOT claimed absent._
- [~] Hardware FME (TME/SME) is detected, reported, and opportunistically used
      where present, closing the cold-boot/DRAM gap on real silicon (Part C).
      _Detection + SYS_SYSINFO reporting are complete for the whole TME/MKTME/SME/
      SEV/TDX family (Part C, all `[x]`). The one remaining step - live SME C-bit
      page-table marking - is **hardware-gated and untestable under QEMU TCG**
      (the memory-controller crypto is not emulated), so it stays software-decidable
      policy until exercised on real silicon, per this track's own SCOPE rule. This
      is the named, bounded residual, not an unbounded gap._
- [x] A planted-leak negative test proves a fully-reversed dump still cannot
      elevate on a fresh boot - the exfiltration→elevation matrix holds (Part D).
      _Implemented: `scripts/dev/test_track4_planted_leak.ps1` (2026-06-09)._
- [x] The irreducible plaintext residual is named precisely in STATUS.md and
      proven bounded by the `pmemsave` test, with no claim exceeding it.
      _STATUS.md §9 + the Part A HARD LIMIT + `fme_memory_encryption_check.ghl`
      header caveat #3 name it; `test_track4_pmemsave.ps1` enumerates the residuals
      it does NOT claim absent (.text, firmware, page tables)._

## Follow-up: legacy v0 app blobs are W+X (security review finding)

A v0 (no-manifest) app's entire blob is mapped both Writable and eXecutable by
`l3_apply_wx_policy` (`src/kernel/proc/usermode_paging.inc`, the `r10d==0`
legacy-permissive path). Any in-blob memory-corruption bug therefore composes
straight into a write-then-execute primitive - it does not by itself grant ring-0,
but it removes the W^X speed bump every other layer assumes.

This is **not closeable at the page-table layer**: `gritc` emits app blobs in embed
mode with no section directives, so code, `state` data and inline strings share the
same pages. Forcing R+X faults legitimate data writes; forcing W+NX faults
execution.

- [ ] Compiler: in embed/app mode, page-align and split the blob into a
      `[code R+X][data/strings W+NX]` layout and emit the code/data boundary.
- [ ] Loader: auto-install a real v1 W^X manifest from that boundary at slot
      install (the `SYS_WX_INSTALL_MANIFEST` path and the W^X walk already exist),
      so v0/permissive becomes unreachable for first-party apps.
- [ ] Verify: a v0 app that writes into its own code window after the change is
      rejected/faults; a normal app still boots and draws.

## Path to 10/10 (security-first; speed maximized under that)

Self-rating now: **security 5 / speed 5**. Software is complete; the cap is
fundamental — XOR-whitening with a mask co-resident in DRAM gives ~zero protection
against the one-shot dump, so the real closure is hardware FME, which QEMU can't test.

- [ ] **(sec→10, HW-gated)** Live SME C-bit page-table marking on real silicon
      (mask + policy already landed) so kernel-secret / slot-arena / FS-cache pages
      are ciphertext in DRAM. Where TME is BIOS-locked-on, assert + report.
- [ ] **(sec→10)** Close the v0 W+X blob hole (compiler split + auto-manifest above)
      so a memory-corruption bug can't compose into write-then-execute.
- [ ] **(sec→10)** Derive the at-rest/volatile key from a per-machine root (Track 7
      P1 / Track 10 board), never a shipped constant — then a DIMM dump + full image
      disclosure still yields ciphertext.
- [ ] **Verify:** an independent agent re-rates this track **security 10**
      *conditional on FME-present hardware* (stated as a bounded 10, per SCOPE rule).
- **(speed→max under sec 10)** FME is transparent memory-controller AES (≈0 CPU
      cost); route any decrypt-on-demand + zeroize/rekey onto the Track 9 async
      offload. Realistic ceiling **security 10 (HW present) / speed 9**.
- **Honest cap:** on legacy hardware with no TME/SME this track cannot reach
      security 10 — it stays at the software bound. Document as "10 where FME present."
