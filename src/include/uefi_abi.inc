; ============================================================================
; Grit - UEFI / PE-COFF / FAT32 ABI constants  (src/boot UEFI loader)
; ----------------------------------------------------------------------------
; Named values for the magic literals the BOOTX64.EFI loader bakes into its
; PE/COFF image header, UEFI BootServices/protocol calls, GOP mode selection,
; the FAT32 DATA.IMG extent walk, and the KASLR slide PRNG. Definitions live
; here; the src/boot/uefi_loader_*.inc files reference the names. Each value
; cites the spec section it comes from so it stays traceable, not just named
; (maintainability-todo.md §4.2).
;
; Spec sources abbreviated below:
;   UEFI   = UEFI Specification 2.10 (Aug 2022)
;   PECOFF = Microsoft PE/COFF Specification rev 11 (2021)
;   FAT    = Microsoft FAT32 File System Specification (FATGEN103, 2000)
;   SDM    = Intel 64 & IA-32 Architectures Software Developer's Manual
;
; All values copied byte-for-byte from the literals they replace; emitting a
; named constant of identical value produces an identical image.
; ============================================================================
%ifndef UEFI_ABI_INC
%define UEFI_ABI_INC

; ----------------------------------------------------------------------------
; PE/COFF image layout (PECOFF §2 "Overview", §3 "Special Sections")
; ----------------------------------------------------------------------------
; Our BOOTX64.EFI is a hand-built PE32+ image with two sections (.text, .reloc).
PE_DOS_MAGIC          equ 0x5A4D        ; "MZ"   DOS header e_magic (PECOFF §2.2)
PE_NT_SIGNATURE       equ 0x00004550    ; "PE\0\0" NT signature (PECOFF §2.3)
PE_MACHINE_X64        equ 0x8664        ; IMAGE_FILE_MACHINE_AMD64 (PECOFF §2.3.1)
PE_CHARACTERISTICS    equ 0x0206        ; EXECUTABLE_IMAGE|LINE_NUMS_STRIPPED|
                                        ; LARGE_ADDRESS_AWARE (PECOFF §2.3.2)
PE_OPT_MAGIC_PE32PLUS equ 0x020B        ; PE32+ optional-header magic (PECOFF §3.4)
PE_SECT_ALIGN         equ 0x1000        ; SectionAlignment = 4 KiB (PECOFF §3.4)
PE_FILE_ALIGN         equ 0x200         ; FileAlignment    = 512 B (PECOFF §3.4)
; Section Characteristics flags (PECOFF §4.1 Table "Section Flags").
PE_SCN_TEXT_RWX       equ 0xE0000060    ; MEM_EXECUTE|MEM_READ|MEM_WRITE|CNT_CODE
PE_SCN_RELOC_RD       equ 0x42000040    ; MEM_DISCARDABLE|MEM_READ|CNT_INIT_DATA

; ----------------------------------------------------------------------------
; UEFI System Table & Boot Services member offsets
; (UEFI §4.3 EFI_SYSTEM_TABLE, §4.4 EFI_BOOT_SERVICES). Offsets are the byte
; position of each function pointer within the 64-bit table (8 B header fields
; + 8 B per preceding pointer). Verified against EDK II MdePkg/Include/Uefi.
; ----------------------------------------------------------------------------
ST_BOOTSVC            equ 96            ; EFI_SYSTEM_TABLE.BootServices
BS_ALLOCPG            equ 40            ; AllocatePages          (UEFI §7.2)
BS_GETMMAP            equ 56            ; GetMemoryMap           (UEFI §7.2)
BS_ALLOCPL            equ 64            ; AllocatePool           (UEFI §7.2)
BS_HNDLPROT           equ 152           ; HandleProtocol         (UEFI §7.3)
BS_OPENPROT           equ 280           ; OpenProtocol           (UEFI §7.3)
BS_LOCHNDL            equ 312           ; LocateHandle/Buffer    (UEFI §7.3)
BS_LOCATE             equ 320           ; LocateProtocol         (UEFI §7.3)
BS_EXITBOOT           equ 232           ; ExitBootServices       (UEFI §7.4)
BS_WATCHDOG           equ 256           ; SetWatchdogTimer       (UEFI §7.5)

; ----------------------------------------------------------------------------
; EFI_GRAPHICS_OUTPUT_PROTOCOL & mode/info member offsets (UEFI §12.9)
; ----------------------------------------------------------------------------
GOP_QUERY             equ 0             ; QueryMode  fn pointer
GOP_SET               equ 8             ; SetMode    fn pointer
GOP_MODE              equ 24            ; ->Mode (EFI_GRAPHICS_OUTPUT_PROTOCOL_MODE)
GOPM_MAX              equ 0             ; Mode.MaxMode (UINT32)
GOPM_CUR              equ 4             ; Mode.Mode    (UINT32, current)
GOPM_FBBASE           equ 24            ; Mode.FrameBufferBase (EFI_PHYSICAL_ADDRESS)
GOPI_HRES             equ 4             ; ModeInfo.HorizontalResolution
GOPI_VRES             equ 8             ; ModeInfo.VerticalResolution
GOPI_PPSL             equ 32            ; ModeInfo.PixelsPerScanLine
GOP_MODE_NONE         equ 0xFFFFFFFF    ; sentinel: no acceptable mode chosen yet

; ----------------------------------------------------------------------------
; Simple File System / File Protocol member offsets (UEFI §13.4, §13.5)
; ----------------------------------------------------------------------------
SFS_OPENVOL           equ 8             ; EFI_SIMPLE_FILE_SYSTEM.OpenVolume
FP_OPEN               equ 8             ; EFI_FILE_PROTOCOL.Open
FP_CLOSE              equ 16            ; EFI_FILE_PROTOCOL.Close
FP_READ               equ 32            ; EFI_FILE_PROTOCOL.Read
FP_WRITE              equ 40            ; EFI_FILE_PROTOCOL.Write
; EFI_FILE_PROTOCOL.Open OpenMode bits (UEFI §13.5 EFI_FILE_MODE_*).
EFI_FILE_MODE_CREATE_RW equ 0x8000000000000003 ; CREATE(1<<63)|WRITE(2)|READ(1)

; ----------------------------------------------------------------------------
; EFI_BLOCK_IO_PROTOCOL member offsets and media layout (UEFI §13.9)
; ----------------------------------------------------------------------------
BIO_MEDIA             equ 8             ; ->Media (EFI_BLOCK_IO_MEDIA*)
BIO_RESET             equ 16            ; Reset fn
BIO_READ              equ 24            ; ReadBlocks fn
BIO_WRITE             equ 32            ; WriteBlocks fn
BIO_FLUSH             equ 40            ; FlushBlocks fn
BIOM_MEDIAID          equ 0             ; Media.MediaId (UINT32)
BIOM_BLKSZ            equ 32            ; Media.BlockSize (UINT32, after 5 BOOLEAN+pad)
BIOM_LASTBLK          equ 40            ; Media.LastBlock (EFI_LBA, u64)

; ----------------------------------------------------------------------------
; FAT32 BPB / directory-entry layout (FAT §3.1 Boot Sector and BPB, §6 Dir)
; ----------------------------------------------------------------------------
BPB32_BYTSPSEC        equ 11            ; BPB_BytsPerSec  (u16)
BPB32_SECPCLUS        equ 13            ; BPB_SecPerClus  (u8)
BPB32_RSVDSEC         equ 14            ; BPB_RsvdSecCnt  (u16)
BPB32_NUMFATS         equ 16            ; BPB_NumFATs     (u8)
BPB32_FATSZ32         equ 36            ; BPB_FATSz32     (u32)
BPB32_ROOTCLUS        equ 44            ; BPB_RootClus    (u32)
BPB32_SIG             equ 510           ; boot-sector signature offset
FAT_BOOTSIG           equ 0xAA55        ; mandatory 0xAA55 (FAT §3.1)
FAT_BYTES_PER_SEC     equ 512           ; only 512-byte sectors supported
DIRENT_ATTR           equ 11            ; DIR_Attr      (FAT §6)
DIRENT_CLUS_HI        equ 20            ; DIR_FstClusHI (u16)
DIRENT_CLUS_LO        equ 26            ; DIR_FstClusLO (u16)
DIRENT_FILE_SIZE      equ 28            ; DIR_FileSize  (u32)
DIRENT_FREE           equ 0xE5          ; deleted-entry marker (FAT §6)
DIRENT_SIZE           equ 32            ; one directory entry is 32 bytes
ATTR_LONG_NAME        equ 0x0F          ; RD|HID|SYS|VOL_ID = LFN entry (FAT §7)
ATTR_DIRECTORY        equ 0x10          ; ATTR_DIRECTORY (FAT §6)
FAT32_EOC             equ 0x0FFFFFF8    ; end-of-clusterchain threshold (FAT §4)
FAT32_ENTRY_MASK      equ 0x0FFFFFFF    ; 28-bit FAT32 entry mask (FAT §4)

; ----------------------------------------------------------------------------
; x86-64 4-level paging: entry flag bits and architectural page sizes
; (SDM Vol.3 §4.5 "4-Level Paging"; bit 63 = XD/NX per SDM Vol.3 §4.6).
; The loader builds its own page tables before ExitBootServices. These mirror
; the kernel's PAGE_* names but are kept local so boot takes no kernel-header
; dependency. PHYS bases below are PT_BASE(0x70000)-relative table pages.
; ----------------------------------------------------------------------------
UEFI_PAGE_PRESENT     equ 0x01          ; P  bit 0
UEFI_PAGE_WRITABLE    equ 0x02          ; R/W bit 1
UEFI_PAGE_USER        equ 0x04          ; U/S bit 2
UEFI_PAGE_LARGE       equ 0x80          ; PS bit 7 (2 MiB / 1 GiB page)
PAGE_SIZE_4K          equ 0x1000        ; 4 KiB
PAGE_SIZE_2M          equ 0x200000      ; 2 MiB large page
PAGE_SIZE_1G          equ 0x40000000    ; 1 GiB large page
PAGE_MASK_2M          equ 0x1FFFFF      ; (2 MiB - 1) round-up mask
; Page-table page physical addresses, contiguous from PT_BASE (boot_memory.inc).
UEFI_PDPT0_PHYS       equ 0x71000       ; PML4[0] -> PDPT covering 0..512 GiB
UEFI_PDPT1_PHYS       equ 0x72000       ; PML4[1] -> PDPT covering 512..1024 GiB
UEFI_PD0_PHYS         equ 0x73000       ; PDPT0[0] -> PD0 covering first 1 GiB
UEFI_PT0_PHYS         equ 0x74000       ; PD0[0] -> 4 KiB PT over 0..2 MiB
UEFI_APP_PT_PHYS      equ 0x75000       ; first of 12 app-arena 4 KiB PTs
; Framebuffer overrun-guard tables (split the LFB's 1 GiB page down to 4 KiB so
; the page just past fb_end can be left unmapped). Contiguous after the
; syscall-stack PT (0x82000); kept inside the nested-kernel monitor's protected
; page-table region (see nk_monitor.asm NK_PT_REGION_HI).
UEFI_FB_PD_PHYS       equ 0x83000       ; PDPT0[fb>>30] -> PD over that 1 GiB
UEFI_FB_PT_PHYS       equ 0x84000       ; PD[fb>>21] -> 4 KiB PT around fb_end
; W^X kernel-text window expressed as 4 KiB PTE indices (0x100000..0x200000).
UEFI_KTEXT_START_PAGE equ 0x100
UEFI_KTEXT_END_PAGE   equ 0x200

; ----------------------------------------------------------------------------
; Kernel image load buffer (loader-chosen; large enough for KERNEL.BIN today)
; ----------------------------------------------------------------------------
KERNEL_LOAD_MAX_BYTES equ 0x2000000   ; 32 MiB cap passed to EFI_FILE.Read
KERNEL_LOAD_MAX_PAGES equ 0x2000       ; 8192 * 4 KiB = 32 MiB (AllocatePages)

; ----------------------------------------------------------------------------
; Previous-boot kernel-log flush region (Grit-internal handoff contract)
; ----------------------------------------------------------------------------
; The kernel leaves a magic-tagged buffer at a fixed low-memory address for the
; next boot's loader to flush to \KLOG.TXT. Not a spec value - a Grit ABI.
;   +0  qword magic "KLOGNS01"   +8 qword payload length   +16 ASCII payload
KLOG_FLUSH_ADDR_LO    equ 0x600000
KLOG_MAGIC_QWORD      equ 0x3130534E474F4C4B  ; "KLOGNS01" little-endian
KLOG_MAX_BYTES        equ 0x100000            ; sanity cap: refuse > 1 MiB

; ----------------------------------------------------------------------------
; Long-mode entry MSR (the loader sets EFER.LME/NXE before its far jump)
; ----------------------------------------------------------------------------
; IA32_EFER selector for RDMSR/WRMSR. Intel SDM Vol.4 Table 2-2 (MSR address
; C000_0080h); AMD APM Vol.2 §3.1.7. Mirrors arch_regs.inc IA32_EFER_MSR but
; kept local so the boot path takes no dependency on kernel headers.
IA32_EFER_MSR         equ 0xC0000080

; ----------------------------------------------------------------------------
; KASLR container & slide PRNG (tools/build/extract_kaslr_fixups.py)
; ----------------------------------------------------------------------------
; Container magic "GRKASLR0" as a little-endian qword (digit groups keep the
; ASCII readable: 0x30='0' 52='R' 4C='L' 53='S' 41='A' 4B='K' 58='X' 4E='N').
KASLR_MAGIC_QWORD     equ 0x3052_4C53_414B_5247
; splitmix64 / PCG-derived mixing constants for deriving the slide from
; RDRAND/RDTSC entropy. These are the well-known golden-ratio + LCG odd
; multipliers (Steele & Vigna, "Fast Splittable PRNGs", 2014; PCG, O'Neill 2014).
KASLR_MIX_GOLDEN      equ 0x9E3779B97F4A7C15  ; 2^64/phi, splitmix64 increment
KASLR_MIX_LCG_MUL     equ 0x5851F42D4C957F2D  ; PCG/Knuth MMIX LCG multiplier
KASLR_MIX_LCG_INC     equ 0x14057B7EF767814F  ; PCG default LCG increment
; Slide window ceiling: KERNEL_STACK_TOP(0xC00000) - STACK_RESERVE(0x40000)
; - KERNEL_LOAD_ADDR(0x100000) = 0xAC0000, minus payload at runtime.
KASLR_SLIDE_CEILING   equ 0xAC0000

%endif ; UEFI_ABI_INC
