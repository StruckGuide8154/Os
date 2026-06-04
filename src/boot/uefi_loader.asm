; ============================================================================
; NexusOS v3.0 - UEFI Bootloader (BOOTX64.EFI)
;
; This file is the boot-order manifest for the active UEFI loader. Keep the
; included sections in emitted-image order; the include files are split by
; cohesive boot stage and intentionally preserve the original assembly flow.
; ============================================================================

; Constants, shared macros, and memory-map aliases.
%include "src/boot/uefi_loader_defs.inc"

; PE/COFF image headers must be emitted first.
%include "src/boot/uefi_loader_pe.inc"

; UEFI entry path: firmware setup, load order, KASLR parse, and handoff.
%include "src/boot/uefi_loader_entry.inc"

; Post-ExitBootServices relocation trampoline copied to low memory.
%include "src/boot/uefi_loader_trampoline.inc"

; Fixed and variable boot-time physical allocations.
%include "src/boot/uefi_loader_memory.inc"

; GOP discovery, mode selection, and VBE handoff publication.
%include "src/boot/uefi_loader_graphics.inc"

; ESP file loading for kernel, apps blob, and DATA.IMG ramdisk.
%include "src/boot/uefi_loader_files.inc"

; FAT32 DATA.IMG extent probing while firmware block I/O is available.
%include "src/boot/uefi_loader_storage_extents.inc"

; Previous-boot kernel-log flush to the ESP.
%include "src/boot/uefi_loader_klog.inc"

; Paging setup, pointer protocol discovery, ExitBootServices, and E820 publish.
%include "src/boot/uefi_loader_paging_exit.inc"

; GDT, protocol GUIDs, UCS-2 paths, and loader variables.
%include "src/boot/uefi_loader_data.inc"

; Raw-size padding and minimal .reloc section.
%include "src/boot/uefi_loader_image_tail.inc"
