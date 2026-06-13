%ifndef BOOT_MEMORY_INC
%define BOOT_MEMORY_INC

; Grit boot memory contract.
; Keep loader, paging, and kernel users on one map while relocation work lands.

STAGE2_LOAD_ADDR    equ 0x7E00
E820_COUNT_ADDR     equ 0x1FF0
E820_MAP_ADDR       equ 0x2000
VBE_INFO_ADDR       equ 0x9000
BOOT_DRIVE_ADDR     equ 0x9100
PAGE_TABLE_ADDR     equ 0x70000
SMP_TRAMPOLINE_ADDR equ 0x8000
; KASLR: build_uefi.ps1 -Kaslr re-assembles the kernel at a second base by
; passing -dKERNEL_BASE_OVERRIDE=<addr>; the override exists only so the build
; can diff two ORGs to derive a fixup table. The runtime base is picked by the
; loader at boot. See tools/build/extract_kaslr_fixups.py.
%ifdef KERNEL_BASE_OVERRIDE
KERNEL_LOAD_ADDR    equ KERNEL_BASE_OVERRIDE
%else
KERNEL_LOAD_ADDR    equ 0x100000
%endif
; Canonical link base of the WRAPPED payload (pass A), independent of the
; two-pass KERNEL_BASE_OVERRIDE diff. Use this - NOT KERNEL_LOAD_ADDR - anywhere
; a constant must compare against the kernel's *unslid* base at runtime: an
; absolute immediate built from KERNEL_LOAD_ADDR differs between the A/B ORG
; passes, so extract_kaslr_fixups.py flags it and the loader relocates it along
; with the slide (making it useless for KASLR self-detection). 0x100000 is the
; same in both passes, so it is never added to the fixup table and survives as
; the true link base. See src/kernel/core/security_status.asm [4].
KERNEL_LINK_BASE    equ 0x100000
KERNEL_STACK_TOP    equ 0xC00000
IDT_ADDR            equ 0xC10000
KERNEL_DATA_ADDR    equ 0xC20000
PAGE_BITMAP_ADDR    equ 0xE00000
PAGE_BITMAP_SIZE    equ 0x100000

; --- Framebuffer / GUI back buffer ---------------------------------------
; The kernel renders into a back buffer that the compositor flips to the
; physical framebuffer. The back buffer is sized for the maximum
; *logical* desktop we support; smaller modes use only the top-left.
;
;   MAX_FB_WIDTH x MAX_FB_HEIGHT x 4 (bpp) must fit in BOOT_BACK_BUFFER_SIZE.
;   Today: 1920 x 1200 x 4 = 9_216_000 bytes -> round up to 0x900000 (9 MiB).
;
; Any caller setting a new mode (display_set_mode syscall) is validated
; against BOOT_BACK_BUFFER_SIZE / 4 pixels; bumping the constants below
; automatically widens the syscall acceptance range.
MAX_FB_WIDTH          equ 1920
MAX_FB_HEIGHT         equ 1200
BACK_BUFFER_ADDR      equ 0x1000000              ; 16 MiB
BOOT_BACK_BUFFER_SIZE equ 0x900000               ; 9 MiB (>= WUXGA*4)
CURSOR_BG_ADDR        equ 0x2400000              ; save buffer + 10 MiB pad
WINDOW_POOL_ADDR      equ 0x2410000
EVENT_BUFFER_ADDR     equ 0x2420000

; --- Userland app arenas ------------------------------------------------
; APP_DATA_ADDR must be 2 MiB aligned because paging.asm derives the
; user PDE index as (APP_DATA_ADDR / 0x200000). Each slot is 2 MiB so the
; generated GritHL app blob, including the full SVG wallpaper renderer, fits
; below the per-slot shadow window/stack.
APP_SLOT_COUNT         equ 12
APP_DATA_ADDR         equ 0x2600000              ; 38 MiB, 2 MiB aligned
APP_SLOT_SIZE         equ 0x200000
APPS_BLOB_ADDR        equ (APP_DATA_ADDR + APP_SLOT_SIZE * APP_SLOT_COUNT)
APPS_BLOB_MAX_SIZE    equ 0x200000
L3_SYSCALL_STACK_ADDR equ (APPS_BLOB_ADDR + APPS_BLOB_MAX_SIZE)

WALLPAPER_CACHE_BYTES equ BOOT_BACK_BUFFER_SIZE
WALLPAPER_CACHE0_ADDR equ (L3_SYSCALL_STACK_ADDR + 0x200000)
WALLPAPER_CACHE1_ADDR equ (WALLPAPER_CACHE0_ADDR + WALLPAPER_CACHE_BYTES)
WALLPAPER_CACHE2_ADDR equ (WALLPAPER_CACHE1_ADDR + WALLPAPER_CACHE_BYTES)
WALLPAPER_CACHE_ADDR  equ WALLPAPER_CACHE0_ADDR  ; legacy alias for cache users
BACK_BUFFER_SAVE_ADDR equ (WALLPAPER_CACHE2_ADDR + WALLPAPER_CACHE_BYTES + 0x100000)
BOOT_ANIM_BUF_ADDR    equ (BACK_BUFFER_SAVE_ADDR + BOOT_BACK_BUFFER_SIZE + 0x100000)
BOOT_ANIM_BUF_SIZE    equ 0x1000000

; App arena 4KB page tables. The arena is split into 4KB pages (one PT per
; covered PDE) so the kernel can mark only the running slot's pages USER and
; enforce W^X per page. APP_SLOT_COUNT PTs cover the full arena
; (APP_SLOT_COUNT * APP_SLOT_SIZE bytes); today that's 12 PTs spanning
; 0x75000..0x80FFF for the 24 MiB arena. The UEFI loader claims PT_BASE..+17
; pages (PML4 + 2*PDPT + PD0 + PT0 + 12 app PTs); the BIOS loader relocates
; PD3 to 0x81000 to keep this region contiguous.
APP_ARENA_PT_BASE     equ 0x75000
ARENA_SLOT_PAGES      equ (APP_SLOT_SIZE / 0x1000) ; 512 4KB pages per slot

; Syscall-stack PT slot. l3_syscall_stacks lives in kernel BSS, inside an
; otherwise 2 MiB-large supervisor PDE in PD0. Both bootloaders reserve a
; physical PT page here so the kernel can split that PDE into 4 KiB pages
; at init time and clear PRESENT on the per-slot guard PTE. The bootloader
; does not know the kernel BSS address - l3_install_syscall_stack_pt
; (src/kernel/proc/usermode.asm) computes the PDE index at runtime, walks
; CR3 to find PD0, populates this PT, and atomically swaps the PDE.
; alignb 0x20000 on l3_syscall_stacks guarantees the array (MAX_WINDOWS *
; L3_SYSCALL_STACK_STRIDE = 192 KiB after the shadow-stack stride widening)
; fits in a single PDE so one PT suffices.
SYSCALL_STACK_PT_BASE equ 0x82000

; --- Paging bit constants used by W^X enforcement ------------------------
; PAGE_NX is bit 63 of the PTE/PDE - requires EFER.NXE=1 (set by both boot
; paths: uefi_loader.asm in the EFER fix-up, stage2.asm in the LME path).
; A page with PAGE_NX cleared is executable iff its CS-selected segment
; permits exec; with PAGE_NX set, instruction fetches from the page fault
; regardless of the rest of the PTE. PAGE_PRESENT/PAGE_WRITABLE/PAGE_USER/
; PAGE_LARGE live in src/include/constants.inc and are unchanged.
PAGE_NX               equ (1 << 63)

; --- Per-slot W^X manifest ------------------------------------------------
; Apps declare which slot-offset range holds executable code. On every slot
; activation (l3_apply_wx_policy), the kernel walks the slot's PT and sets
; pages inside [code_start_off, code_end_off) to X+!W (PAGE_NX clear, W=0)
; and all other slot pages (including the stack/shadow region) to W+NX.
;
; Manifest layout (lives inside the slot's metadata region [0, 512)):
;   off 0x00 .. 0x07  L3_SLOT_MAGIC                  (existing)
;   off 0x08 .. 0x0F  SLOT_META_WX_MANIFEST_VER      (u64)
;   off 0x10 .. 0x17  SLOT_META_WX_CODE_START_OFF    (u64, 4KB-aligned)
;   off 0x18 .. 0x1F  SLOT_META_WX_CODE_END_OFF      (u64, 4KB-aligned)
;
; Manifest versions:
;   0 - absent. Legacy fallback: every blob page stays W+X (no NX, W=1).
;       Stack/shadow page (and any future enforced region) still W+NX.
;       This lets existing apps boot unchanged while individual apps
;       migrate to declaring a manifest.
;   1 - present. Kernel enforces strict W+NX everywhere except
;       [code_start_off, code_end_off) which becomes X+!W. Both bounds
;       must be 4KB-aligned and inside [L3_APP_CODE_OFF, L3_SHADOW_WIN_OFF);
;       a malformed manifest is treated as version 0 (defensive fallback,
;       logged on the debug serial).
;
; SYS_MPROTECT_WX (syscall #68) flips individual pages within the declared
; code range between W+NX (mode 0) and X+!W (mode 1). Pages outside the
; declared range are rejected - apps that want JIT must declare a code
; range that covers their JIT pages.
SLOT_META_WX_MANIFEST_VER_OFF   equ 0x08
SLOT_META_WX_CODE_START_OFF_OFF equ 0x10
SLOT_META_WX_CODE_END_OFF_OFF   equ 0x18

; SYS_MPROTECT_WX modes (mirror in src/include/syscall_user.inc).
MPROT_WX_MODE_WNX      equ 0       ; W=1, NX=1 (data)
MPROT_WX_MODE_XRO      equ 1       ; W=0, NX=0 (code)

; (The slot-internal constants L3_APP_CODE_OFF / L3_SHADOW_WIN_OFF are
; defined locally in usermode.asm - NASM `equ` cannot be %ifndef-guarded,
; so syscall.asm and any other consumer of those values must redeclare
; them with the same expressions. Keep this comment as the canonical
; reference for what they should be:
;   L3_APP_CODE_OFF    = 512
;   L3_SHADOW_WIN_OFF  = APP_SLOT_SIZE - 512)

; Per-slot user-stack guard page. The user stack top is
; L3_SHADOW_WIN_OFF - 16 = APP_SLOT_SIZE - 528 = 0x1FFDF0; the stack grows
; down 16 KiB (L3_USER_STACK_SIZE) to 0x1FBDF0. Page containing the lowest
; reachable byte is 0x1FB000; the page immediately below - 0x1FA000 - is
; cleared of PAGE_PRESENT in paging setup, so a stack overflow faults into
; isr_common_stub's guard fast path instead of clobbering slot data.
; PTE index within the slot's PT = 0x1FA000 / 0x1000 = 0x1FA.
L3_SLOT_USER_STACK_GUARD_OFF equ 0x1FA000
L3_SLOT_USER_STACK_GUARD_PTE equ (L3_SLOT_USER_STACK_GUARD_OFF / 0x1000)

GUI_LLC_ARENA_START equ BACK_BUFFER_ADDR
GUI_LLC_ARENA_END   equ APP_DATA_ADDR

VBE_FB_ADDR_OFF     equ 0x00
VBE_WIDTH_OFF       equ 0x08
VBE_HEIGHT_OFF      equ 0x0C
VBE_PITCH_OFF       equ 0x10
VBE_BPP_OFF         equ 0x14
VBE_SPP_OFF         equ 0x18
VBE_APPS_BASE_OFF   equ 0x20
VBE_APPS_SIZE_OFF   equ 0x28
VBE_BACKBUF_OFF     equ 0x30
VBE_BACKBUF_SIZE_OFF equ 0x38
VBE_APP_ARENA_BASE_OFF equ 0x40
VBE_APP_ARENA_SIZE_OFF equ 0x48

; --- FAT16 ramdisk (DATA.IMG) ---------------------------------------------
; The kernel's FAT16 driver runs on top of an LBA-addressed block device.
; On QEMU we attach build/data.img as an IDE drive; on real hardware
; (NVMe-only laptops, USB-boot) there is no legacy IDE controller, so the
; UEFI loader instead loads \EFI\BOOT\DATA.IMG into RAM and writes its
; base/size here. ata.asm consults ramdisk.asm first; if an LBA falls
; inside the registered region the read/write is satisfied from RAM,
; otherwise it falls through to ATA PIO. Both paths see the same FAT16
; volume and the rest of the kernel is unaware of the source.
;
; Size: bumped here if build/data.img outgrows the limit. The loader
; rejects images larger than DATA_IMG_MAX_SIZE; the kernel only ever
; reads up to the registered size (so a smaller actual file is fine).
VBE_RAMDISK_BASE_OFF   equ 0x50
VBE_RAMDISK_SIZE_OFF   equ 0x58
DATA_IMG_MAX_SIZE      equ 0x2000000   ; 32 MiB cap - bumped 2026-05-26 to fit Phoenix GFX FW set

; --- Persistent storage backing (Phase 1 contract) ------------------------
; The UEFI loader, while firmware services are still available, resolves
; the physical disk LBA extents of \EFI\BOOT\DATA.IMG and records them
; here so the kernel can flush dirty ramdisk pages back to the same on-disk
; bytes after ExitBootServices. Without this contract, real-hardware FS
; writes are session-only (see src/kernel/drivers/ramdisk.asm header).
;
; Storage class tells the kernel which driver to dispatch the flush to:
;   0 = none (session-only, current behavior)
;   1 = NVMe        (src/kernel/drivers/nvme.asm - Phase 2)
;   2 = USB-MSC     (src/kernel/drivers/usb_msc.asm - Phase 3)
;   3 = legacy ATA  (existing ata.asm - QEMU only)
;
; Extent table format: array of {u64 start_lba, u32 sector_count, u32 _pad}
; written to STORAGE_EXTENTS_ADDR by the loader. Cap = STORAGE_EXTENTS_MAX
; entries (FAT32 fragmentation on a fresh ESP rarely exceeds a handful).
VBE_STORAGE_CLASS_OFF   equ 0x60   ; u8 (above values)
VBE_STORAGE_LUN_OFF     equ 0x61   ; u8 (NVMe NSID or USB LUN)
VBE_STORAGE_BLKSIZE_OFF equ 0x62   ; u16 (logical block size, usually 512)
VBE_STORAGE_EXT_CNT_OFF equ 0x64   ; u32 (number of extents written)
VBE_STORAGE_EXT_PTR_OFF equ 0x68   ; u64 (physical pointer to extent array)

; --- Runtime feature-toggle config (BOOTCFG.TXT) --------------------------
; The UEFI loader reads the OPTIONAL ESP file \EFI\BOOT\BOOTCFG.TXT into
; firmware RAM and publishes (base,size) here. The kernel's GHLK module
; boot_features.ghl (boot_features_init) parses it into the feat_mask bitmask
; that gates subsystem init / per-frame work / individual syscalls. Absent
; file -> size 0 -> default-everything-on (byte-compatible with prior boots).
VBE_BOOTCFG_BASE_OFF    equ 0x70   ; u64 base of the loaded config text (0 = none)
VBE_BOOTCFG_SIZE_OFF    equ 0x78   ; u64 byte length of the config text
BOOTCFG_MAX_SIZE        equ 0x1000 ; 4 KiB cap (one firmware page)

; --- Track 2 signed-artifact envelopes (SYSSIG.ENV / KUPDATE.ENV) ----------
; The loader reads two OPTIONAL signed-artifact envelope files
; (docs/signed-artifact-envelope.md v1) from the ESP and publishes (base,size)
; here for the kernel's envelope gate (src/kernel/grithlk/envelope_gate.ghl):
;   SYSSIG.ENV  - REQUIRED by the kernel (fail-closed): quorum-signed envelope
;                 whose payload is the per-app integrity table; verified via
;                 envelope_verify_signed at boot (K5) before any app runs.
;   KUPDATE.ENV - optional staged update artifact; accepted/rejected through
;                 the same gate (the only admission path for update input).
; Absent file -> base/size 0 (kernel policy: SYSSIG missing = boot panic,
; KUPDATE missing = "no update staged").
VBE_SYSSIG_BASE_OFF     equ 0x80   ; u64 base of loaded SYSSIG.ENV (0 = none)
VBE_SYSSIG_SIZE_OFF     equ 0x88   ; u64 byte length
VBE_KUPDATE_BASE_OFF    equ 0x90   ; u64 base of loaded KUPDATE.ENV (0 = none)
VBE_KUPDATE_SIZE_OFF    equ 0x98   ; u64 byte length
SYSSIG_MAX_SIZE         equ 0x2000   ; 8 KiB cap (header + 1460B payload + sigs)
KUPDATE_MAX_SIZE        equ 0x100000 ; 1 MiB cap for a staged update envelope

; --- Track 2 quorum-change tracking path (KQUORUM.ENV) ---------------------
; Optional staged quorum-change artifact: a policy-class envelope whose
; payload requests raising the active per-class threshold quorum. Admitted
; only by quorum_change_admit (envelope_gate.ghl), which requires the
; signature set to satisfy BOTH the current (old) and the proposed (new)
; quorum and validates the transition via security_threshold_change_valid.
; Absent file -> base/size 0 -> "no quorum change staged".
VBE_KQUORUM_BASE_OFF    equ 0xA0   ; u64 base of loaded KQUORUM.ENV (0 = none)
VBE_KQUORUM_SIZE_OFF    equ 0xA8   ; u64 byte length
KQUORUM_MAX_SIZE        equ 0x2000 ; 8 KiB cap (header + 18B payload + sigs)

; --- Track 2 loader-side KERNEL.BIN envelope (KERNEL.ENV) -------------------
; The last "no unsigned input" residual: KERNEL.ENV is a kernel-class
; quorum-signed envelope whose 32-byte payload is the SHA-256 of the
; KERNEL.BIN container file. The loader publishes (base,size) of the loaded
; envelope AND of the PRISTINE container bytes it read from disk (the
; trampoline copies the payload out, so the firmware-allocated read buffer
; stays byte-identical to the at-rest file). kernel_env_verify_boot
; (envelope_gate.ghl, kmain K5) re-hashes those pristine bytes and verifies
; the envelope FAIL-CLOSED - missing/rejected/mismatched = kernel panic.
VBE_KERNENV_BASE_OFF    equ 0xB0   ; u64 base of loaded KERNEL.ENV (0 = none)
VBE_KERNENV_SIZE_OFF    equ 0xB8   ; u64 byte length
VBE_KIMG_BASE_OFF       equ 0xC0   ; u64 base of pristine KERNEL.BIN file bytes
VBE_KIMG_SIZE_OFF       equ 0xC8   ; u64 byte length actually read
KERNENV_MAX_SIZE        equ 0x2000 ; 8 KiB cap (header + 32B payload + sigs)

; --- Track 2 staged per-class artifact envelopes ---------------------------
; OPTIONAL loader-staged envelopes exercising driver / config / policy classes.
; Admitted through artifact_gate_admit by boot_artifact_class_check
; (envelope_gate.ghl, kmain K5). Missing file -> base/size 0. Verdict latched.
VBE_DRVENV_BASE_OFF     equ 0xD0   ; u64 base of loaded DRIVER.ENV (0 = none)
VBE_DRVENV_SIZE_OFF     equ 0xD8
VBE_CFGENV_BASE_OFF     equ 0xE0   ; u64 base of loaded CONFIG.ENV (0 = none)
VBE_CFGENV_SIZE_OFF     equ 0xE8
VBE_POLENV_BASE_OFF     equ 0xF0   ; u64 base of loaded POLICY.ENV (0 = none)
VBE_POLENV_SIZE_OFF     equ 0xF8
CLASSENV_MAX_SIZE       equ 0x100000 ; 1 MiB cap (driver/config/policy payload)

; Feature bits - MUST stay in lockstep with src/kernel/grithlk/boot_features.ghl.
; (asm callers - e.g. the SYS_DISPLAY_SET_MODE gate - use these names.)
FEAT_CURSOR_DRAW           equ 1
FEAT_FRAME_PRESENT_REFRESH equ 2
FEAT_FRAME_PACING          equ 4
FEAT_MOUSE_INIT            equ 8
FEAT_HID_INIT              equ 16
FEAT_SYSCALL_SET_MODE      equ 32
FEAT_DISPLAY_INIT          equ 64
FEAT_FBPERF_WC             equ 128
FEAT_FX_BENCH              equ 256

STORAGE_EXTENTS_ADDR    equ 0x9200   ; 4 KiB scratch for extent table
STORAGE_EXTENTS_MAX     equ 256      ; max extents (256 * 16B = 4 KiB)
STORAGE_EXTENT_SIZE     equ 16       ; bytes per extent entry

; --- Per-slot handle table (pointer-table refactor) ----------------------
; Indexed, slot-local table; ring 3 sees only opaque packed u32 handles -
; same shape as iOS Mach port rights / Linux fds. As of Phase 2,
; SYS_FS_ENTRY returns a HANDLE_KIND_DIR_ENTRY handle, the FN_KIND_HANDLE
; validator arm calls handle_resolve, and FS syscall handlers translate
; handle -> kernel entry pointer via sc_resolve_dir_entry_arg. Ring 3
; reads entry fields by value through SYS_FS_ENTRY_INFO.
;
; Lives at slot+0x1D5000. The 16 KiB region at slot+0x1D1000..0x1D5000
; was the legacy dir-entry snapshot cache (now unused - kept as a hole
; for the next per-slot cache that needs it). Well below the user-stack
; guard at slot+0x1FA000.
L3_HANDLE_TABLE_OFF     equ 0x1D5000
HANDLE_TABLE_CAP        equ 64
L3_HANDLE_ENTRY_SIZE    equ 16
L3_HANDLE_TABLE_SZ      equ (HANDLE_TABLE_CAP * L3_HANDLE_ENTRY_SIZE) ; 1 KiB

; Handle kinds. 0 marks a free slot in the table; allocations always use
; a non-zero kind so "free" is unambiguous.
HANDLE_KIND_NONE        equ 0
HANDLE_KIND_DIR_ENTRY   equ 1
HANDLE_KIND_XML_NODE    equ 2     ; reserved for follow-up migration
HANDLE_KIND_NET_SOCKET  equ 3     ; reserved
HANDLE_KIND_WINDOW      equ 4     ; reserved (today win_id is a bare int)

; Per-slot soft quota on live handles (max FD count). The table's physical
; capacity (HANDLE_TABLE_CAP) is the hard ceiling; a per-manifest quota may
; lower it. handle_alloc fails once a slot reaches its quota. Default quota =
; full capacity (no extra restriction) until a manifest narrows it via
; handle_set_quota. Stored in kernel BSS (slot_handle_quota[] in
; handle_table.inc), not in the slot's own (ring-3-writable) memory.
HANDLE_DEFAULT_QUOTA    equ HANDLE_TABLE_CAP

; Per-entry flags byte (HANDLE_ENT_FLAGS_OFF). A sealed handle is bound to the
; slot it was issued to and any transfer/duplication path must refuse it.
HANDLE_FLAG_SEALED      equ 0x01

; Per-entry layout (16 bytes):
;   off 0  u8  kind             (0 = free)
;   off 1  u8  flags            (HANDLE_FLAG_*; 0 = none)
;   off 2  u16 generation       (monotonic; allocator wraps 0xFFFF -> 1
;                                so a valid generation is never 0)
;   off 4  u32 reserved
;   off 8  u64 payload          (kind-specific)
HANDLE_ENT_KIND_OFF     equ 0
HANDLE_ENT_FLAGS_OFF    equ 1
HANDLE_ENT_GEN_OFF      equ 2
HANDLE_ENT_PAYLOAD_OFF  equ 8

; Ring-3-visible u32 handle encoding:
;   bits [ 5: 0]  slot index (0..HANDLE_TABLE_CAP-1)
;   bits [21: 6]  generation (16-bit; must match the stored gen)
;   bits [29:22]  kind tag    (8-bit;  must match the stored kind)
;   bits [31:30]  magic 0b10  (rejects bare scalars/pointers misused as
;                              handles - random ring-3 values rarely set
;                              exactly this two-bit pattern)
; Handle value 0 is reserved as INVALID. The allocator never returns 0
; because (a) a fresh entry has generation >= 1 and (b) kind >= 1.
HANDLE_INDEX_MASK       equ 0x3F
HANDLE_GEN_SHIFT        equ 6
HANDLE_GEN_MASK         equ 0xFFFF
HANDLE_KIND_SHIFT       equ 22
HANDLE_KIND_MASK        equ 0xFF
HANDLE_MAGIC_SHIFT      equ 30
HANDLE_MAGIC            equ 2          ; 0b10
HANDLE_MAGIC_MASK       equ 3          ; 0b11

%endif
