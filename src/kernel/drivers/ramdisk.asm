; ============================================================================
; GritOS v3.0 - In-memory block device (RAM disk)
; ----------------------------------------------------------------------------
; Provides an LBA-addressed read/write window over a contiguous region of
; physical RAM. The UEFI loader fills `\EFI\BOOT\DATA.IMG` into firmware-
; allocated pages and publishes (base, size) via VBE_INFO; ramdisk_init
; reads those fields and registers the region. ata.asm then consults
; ramdisk_intercept_{read,write} on every block I/O and short-circuits any
; LBA that falls inside the window. LBAs outside the window keep using
; legacy ATA PIO, so QEMU's `if=ide` data disk is unaffected.
;
; Design notes:
;   * Region is mapped at a single LBA base (FAT16_PART_LBA today). The
;     fat16.asm driver already adds FAT16_PART_LBA to every cluster/FAT/
;     directory sector, so the ramdisk's logical sector 0 corresponds to
;     the start of the FAT16 partition image written by build_uefi.ps1.
;   * Only ONE region is supported. Extending this to multiple regions is
;     straightforward (turn the four state words into an array), but no
;     current caller needs it.
;   * Reads are always satisfied if registered. Writes are also satisfied;
;     they are *not* propagated back to the original DATA.IMG file. Real
;     hardware therefore has session-only persistence, which matches what
;     QEMU users get without `-snapshot=off`.
;   * Public API:
;       ramdisk_init                       - call once at boot
;       ramdisk_register(rdi=base, rsi=lba, edx=sector_count)
;       ramdisk_present                    - eax = 1 if registered
;       ramdisk_intercept_read (rdi=LBA, rsi=dst, edx=sect)
;       ramdisk_intercept_write(rdi=LBA, rsi=src, edx=sect)
;          - eax = 1 if handled (no further work needed)
;          - eax = 0 if LBA is outside the region (caller falls back)
;          - eax = -1 if LBA partially overlaps the region (treated as
;            a programming error; caller should report failure)
; ============================================================================
bits 64

%include "constants.inc"

section .text

global ramdisk_init
global ramdisk_register
global ramdisk_present
global ramdisk_intercept_read
global ramdisk_intercept_write
global ramdisk_mark_dirty
global ramdisk_flush
global ramdisk_storage_class

; ----------------------------------------------------------------------------
; ramdisk_init - Read VBE_INFO ramdisk fields written by the UEFI loader and
; register the region if present. Safe to call when boot info is empty
; (e.g. BIOS boot today) - it simply leaves the ramdisk unregistered.
; ----------------------------------------------------------------------------
ramdisk_init:
    push rdi
    push rsi
    push rdx
    push rax

    mov rax, [abs VBE_INFO_ADDR + VBE_RAMDISK_BASE_OFF]
    test rax, rax
    jz .ri_done

    mov rdx, [abs VBE_INFO_ADDR + VBE_RAMDISK_SIZE_OFF]
    test rdx, rdx
    jz .ri_done

    ; Sanity cap: refuse anything larger than DATA_IMG_MAX_SIZE so a corrupt
    ; boot-info field cannot make the kernel treat arbitrary RAM as disk.
    cmp rdx, DATA_IMG_MAX_SIZE
    ja .ri_done

    ; sector_count = size / 512 (truncate any tail < 1 sector)
    shr rdx, 9
    test rdx, rdx
    jz .ri_done

    mov rdi, rax                ; base
    ; The UEFI loader ships the *stripped* FAT16 partition to the ESP
    ; (build_uefi.ps1 skips the (KERNEL_START_SECTOR + KERNEL_SECTORS)
    ; zero header before WriteAllBytes), so byte 0 of the buffer is the BPB.
    ; fat16.asm computes LBAs in whole-disk coordinates and so always offsets
    ; by FAT16_PART_LBA; register the ramdisk at that LBA base so the BPB
    ; request (LBA FAT16_PART_LBA) maps to byte 0 of the buffer.
    mov esi, FAT16_PART_LBA
    call ramdisk_register

.ri_done:
    pop rax
    pop rdx
    pop rsi
    pop rdi
    ret

; ----------------------------------------------------------------------------
; ramdisk_register(rdi=ram_base, esi=lba_base, edx=sector_count)
; ----------------------------------------------------------------------------
ramdisk_register:
    mov [ramdisk_base], rdi
    mov [ramdisk_lba_base], esi
    mov [ramdisk_sectors], edx
    mov byte [ramdisk_active], 1
    xor eax, eax
    ret

; ----------------------------------------------------------------------------
; ramdisk_present -> eax = 1 if a region is registered, else 0
; ----------------------------------------------------------------------------
ramdisk_present:
    movzx eax, byte [ramdisk_active]
    ret

; ----------------------------------------------------------------------------
; Internal: classify an [LBA, LBA+count) request against the region.
;   rdi = LBA, edx = count
; Returns:
;   eax = 1  -> entirely inside, r8 = byte_offset_into_region, r9 = byte_count
;   eax = 0  -> entirely outside
;   eax = -1 -> partial overlap (caller treats as error)
; Clobbers: rax, r8, r9, r10
; ----------------------------------------------------------------------------
ramdisk_classify:
    cmp byte [ramdisk_active], 1
    jne .out                    ; no region -> outside

    mov r10d, [ramdisk_lba_base]
    mov eax, edi
    cmp eax, r10d
    jb .maybe_outside           ; LBA < base: outside or partial

    ; offset_sectors = LBA - base
    sub eax, r10d
    ; end_sectors = offset + count
    mov r8d, eax
    add r8d, edx
    ; if end > region_sectors -> partial overlap (extending beyond region)
    cmp r8d, [ramdisk_sectors]
    ja .partial

    ; Inside. Translate to byte offset / byte count.
    mov r9d, edx
    shl r9, 9                   ; byte_count = sectors * 512
    shl rax, 9                  ; byte_offset = (LBA - base) * 512
    mov r8, rax
    mov eax, 1
    ret

.maybe_outside:
    ; LBA is below region base. Does the request reach into the region?
    ; LBA + count compared to base.
    mov eax, edi
    add eax, edx
    cmp eax, r10d
    ja .partial                 ; spans the boundary
.out:
    xor eax, eax
    ret

.partial:
    mov eax, -1
    ret

; ----------------------------------------------------------------------------
; ramdisk_intercept_read(rdi=LBA, rsi=dst, edx=sect) -> eax (see header)
; ----------------------------------------------------------------------------
ramdisk_intercept_read:
    push rcx
    push rdi
    push rsi
    push rdx
    push r8
    push r9
    push r11

    ; Save dst in r11 (NOT r10) - ramdisk_classify's header documents that
    ; it clobbers r10 (uses it to hold lba_base). Pre-2026-05-26 this used
    ; r10 and the dst pointer was silently overwritten with FAT16_PART_LBA,
    ; making the memcpy write into low memory and leaving FAT16_SECTOR_BUF
    ; untouched - the BPB read appeared to succeed but the buffer never
    ; got the data, so fat16_init bailed at the signature check.
    mov r11, rsi
    call ramdisk_classify
    cmp eax, 1
    jne .ir_done                ; outside (0) or partial overlap (-1)

    ; memcpy(r11, ramdisk_base + r8, r9)
    mov rsi, [ramdisk_base]
    add rsi, r8
    mov rdi, r11
    mov rcx, r9
    cld
    rep movsb
    mov eax, 1

.ir_done:
    pop r11
    pop r9
    pop r8
    pop rdx
    pop rsi
    pop rdi
    pop rcx
    ret

; ----------------------------------------------------------------------------
; ramdisk_intercept_write(rdi=LBA, rsi=src, edx=sect) -> eax (see header)
; ----------------------------------------------------------------------------
ramdisk_intercept_write:
    push rcx
    push rdi
    push rsi
    push rdx
    push r8
    push r9
    push r11

    ; Save src in r11 (not r10 - see intercept_read for the bug history).
    mov r11, rsi
    call ramdisk_classify
    cmp eax, 1
    jne .iw_done

    mov rdi, [ramdisk_base]
    add rdi, r8
    mov rsi, r11
    mov rcx, r9
    cld
    rep movsb
    ; Mark touched 4KB pages dirty so ramdisk_flush can write them back to
    ; the physical extents recorded by the loader. r8 = byte offset into
    ; region, r9 = byte count. Both are sector-aligned (512) so we round
    ; down/up to page boundaries safely.
    mov rdi, r8
    mov rsi, r9
    call ramdisk_mark_dirty
    mov eax, 1

.iw_done:
    pop r11
    pop r9
    pop r8
    pop rdx
    pop rsi
    pop rdi
    pop rcx
    ret

; ----------------------------------------------------------------------------
; ramdisk_mark_dirty(rdi=byte_offset_into_region, rsi=byte_count)
; Sets dirty bits in ramdisk_dirty_bitmap for every 4KB page touched.
; Each bit covers one 4KB page; bitmap sized for DATA_IMG_MAX_SIZE.
; ----------------------------------------------------------------------------
ramdisk_mark_dirty:
    push rax
    push rcx
    push rdx
    push rdi
    push rsi

    ; end = (offset + count + 0xFFF) >> 12 (page index, exclusive)
    mov rax, rdi
    add rax, rsi
    add rax, 0xFFF
    shr rax, 12
    ; start = offset >> 12
    shr rdi, 12
    cmp rdi, rax
    jae .md_done

    ; Cap end to bitmap size to avoid OOB writes.
    mov rdx, DATA_IMG_MAX_SIZE >> 12
    cmp rax, rdx
    jbe .md_end_ok
    mov rax, rdx
.md_end_ok:
    cmp rdi, rax
    jae .md_done

.md_loop:
    mov rcx, rdi
    shr rcx, 3                 ; byte index = page_idx / 8
    mov rdx, rdi
    and edx, 7
    mov al, 1
    push rcx
    mov cl, dl
    shl al, cl
    pop rcx
    or [ramdisk_dirty_bitmap + rcx], al
    inc rdi
    cmp rdi, rax
    jb .md_loop

.md_done:
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rax
    ret

; ----------------------------------------------------------------------------
; ramdisk_storage_class -> eax = configured storage class (0 = none, 1=NVMe,
; 2=USB-MSC, 3=ATA). Read once at boot from VBE_INFO.
; ----------------------------------------------------------------------------
ramdisk_storage_class:
    movzx eax, byte [abs VBE_INFO_ADDR + VBE_STORAGE_CLASS_OFF]
    ret

; ----------------------------------------------------------------------------
; ramdisk_flush -> eax = 0 on success, -1 on error, 1 if no backing
; Walks the dirty bitmap and writes every dirty 4KB page (8 sectors) back to
; its on-disk LBA through the storage extents table. Clears the bit on
; successful write. Called from:
;   * 1 Hz tick from main loop (best-effort)
;   * shutdown syscall (must complete)
;
; Phase 1 status: write-back is not implemented yet. The dispatch table to
; nvme_write_sectors / usb_msc_write_sectors lands in Phase 4 (blkdev.asm),
; which is blocked on the kernel block-device backing driver - tracked as
; issue #21 (same blocker as the loader's partition-relative LBA item). Today
; this returns 1 ("no backing configured") so behavior is unchanged.
; ----------------------------------------------------------------------------
ramdisk_flush:
    movzx eax, byte [abs VBE_INFO_ADDR + VBE_STORAGE_CLASS_OFF]
    test eax, eax
    jnz .rf_have_backing
    mov eax, 1
    ret
.rf_have_backing:
    ; Phase 4 plan (see #21): for each dirty page idx p in ramdisk_dirty_bitmap:
    ;   1. translate p*8 (sector_in_region) -> physical_lba via the loader's
    ;      extent table at [VBE_STORAGE_EXT_PTR_OFF].
    ;   2. blk_write(class, lba, ramdisk_base + p*4096, 8 sectors).
    ;   3. on success, clear the bit.
    ; Returns 0 when no dirty pages remain.
    xor eax, eax
    ret

section .data
align 8
ramdisk_base       dq 0
ramdisk_lba_base   dd 0
ramdisk_sectors    dd 0    ; in 512-byte sectors
ramdisk_active     db 0

section .bss
alignb 8
; One bit per 4 KiB page over the DATA_IMG_MAX_SIZE window.
; DATA_IMG_MAX_SIZE / 4096 / 8 = 16 MiB / 4 KiB / 8 = 512 bytes today.
ramdisk_dirty_bitmap  resb (DATA_IMG_MAX_SIZE / 4096 / 8)
