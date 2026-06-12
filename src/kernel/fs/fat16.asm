; ============================================================================
; GritOS v3.0 - FAT16 Filesystem Driver
; Reads/writes files from a FAT16 partition starting at a fixed sector offset
; ============================================================================
bits 64

%include "constants.inc"

section .text

; auto-wrapped (FN_BEGIN emits global): global fat16_init
global fat16_list_dir
; auto-wrapped (FN_BEGIN emits global): global fat16_read_file
; auto-wrapped (FN_BEGIN emits global): global fat16_write_file
; auto-wrapped (FN_BEGIN emits global): global fat16_delete_entry
; auto-wrapped (FN_BEGIN emits global): global fat16_rename_entry
; auto-wrapped (FN_BEGIN emits global): global fat16_mkdir
; auto-wrapped (FN_BEGIN emits global): global fat16_get_file_size
; auto-wrapped (FN_BEGIN emits global): global fat16_file_count
; auto-wrapped (FN_BEGIN emits global): global fat16_get_entry

extern ata_read_sectors
extern ata_write_sectors
extern ata_drive_sel
extern kernel_canary
extern kernel_panic_canary

; The FAT16 partition starts after the fixed BIOS kernel reservation.
; Keep this in constants.inc so the BIOS image builder and filesystem agree.
FAT16_FAT_CACHE_SECTORS equ 128
FAT16_ROOT_CACHE_SECTORS equ 32
FAT16_MAX_FAT_ENTRIES equ (FAT16_FAT_CACHE_SECTORS * 256)

; FAT16 BPB offsets (from start of boot sector)
BPB_BYTES_PER_SECT  equ 11        ; word
BPB_SECT_PER_CLUS   equ 13        ; byte
BPB_RESERVED_SECTS  equ 14        ; word
BPB_NUM_FATS        equ 16        ; byte
BPB_ROOT_ENTRIES    equ 17        ; word
BPB_TOTAL_SECTS16   equ 19        ; word
BPB_FAT_SIZE16      equ 22        ; word

; FAT16 directory entry offsets
DIR_NAME            equ 0          ; 8 bytes filename
DIR_EXT             equ 8          ; 3 bytes extension
DIR_ATTR            equ 11         ; 1 byte attributes
DIR_FIRST_CLUS_HI   equ 20        ; 2 bytes (FAT32 only, 0 for FAT16)
DIR_FIRST_CLUS_LO   equ 26        ; 2 bytes
DIR_FILE_SIZE       equ 28         ; 4 bytes
DIR_ENTRY_SIZE      equ 32

; Snapshot-on-open (security_todo.md §5): per-slot captured dir-entry identity.
; Layout per slot: name+ext[11] | first_cluster_lo (u16) | size (u32) = 17 bytes.
FAT16_SNAP_STRIDE   equ 17

; Per-slot cwd ownership sentinel for fat16_cache_owner (see the BSS block):
; "no slot owns the live cache" - forces the next FS syscall to re-materialize.
FAT16_CACHE_OWNER_NONE equ 0xFFFFFFFF

; Attributes
ATTR_READ_ONLY      equ 0x01
ATTR_HIDDEN         equ 0x02
ATTR_SYSTEM         equ 0x04
ATTR_VOLUME_ID      equ 0x08
ATTR_DIRECTORY      equ 0x10
ATTR_ARCHIVE        equ 0x20
ATTR_LFN            equ 0x0F

; Temp buffers. Cache32Max keeps these cold buffers outside the 4MB..16MB GUI
; LLC arena and outside the 16MB..24MB app arena.
%ifdef GRIT_CACHE32_MAX
FAT16_SECTOR_BUF    equ 0x1A00000   ; 512 byte sector buffer
FAT16_FAT_CACHE     equ 0x1A01000   ; FAT table cache (up to 64KB)
FAT16_ROOT_CACHE    equ 0x1A11000   ; Root directory cache (up to 32 sectors = 16KB)
FAT16_ROOT_CACHE_CANARY equ FAT16_ROOT_CACHE + (FAT16_ROOT_CACHE_SECTORS * 512)
FAT16_FILE_BUF      equ 0x1A21000   ; File read buffer (up to 64KB)
FAT16_DIR_CACHE     equ 0x1A31000   ; Current directory listing cache
%else
; Moved to 13MB region to avoid XHCI conflict (0x900000-0x9F0000)
FAT16_SECTOR_BUF    equ 0xD00000   ; 512 byte sector buffer
FAT16_FAT_CACHE     equ 0xD01000   ; FAT table cache (up to 64KB)
FAT16_ROOT_CACHE    equ 0xD11000   ; Root directory cache (up to 32 sectors = 16KB)
FAT16_ROOT_CACHE_CANARY equ FAT16_ROOT_CACHE + (FAT16_ROOT_CACHE_SECTORS * 512)
FAT16_FILE_BUF      equ 0xD21000   ; File read buffer (up to 64KB)
FAT16_DIR_CACHE     equ 0xD31000   ; Current directory listing cache
%endif

%include "src/kernel/fs/fat16_init.inc"
%include "src/kernel/fs/fat16_io.inc"
%include "src/kernel/fs/fat16_dirops.inc"
%include "src/kernel/fs/fat16_nav.inc"
