; ============================================================================
; GritOS - legacy BIOS boot-path constants  (src/boot mbr/stage2/vesa/paging)
; ----------------------------------------------------------------------------
; Named values for the magic literals the BIOS loader bakes into its real-mode
; firmware calls (INT 15h E820 memory map, VESA/VBE), the long-mode entry MSR,
; and its page-table setup. Definitions live here; the .asm files reference the
; names. Each value cites its spec source (maintainability-todo.md §4.2).
;
; Spec sources:
;   ACPI  = ACPI Specification §15 (E820 / "System Address Map")
;   VBE   = VESA BIOS Extensions (VBE) Core Functions Standard 3.0
;   SDM   = Intel 64 & IA-32 Architectures Software Developer's Manual
;
; Physical RAM addresses for the boot map are in src/include/boot_memory.inc;
; this header is for the BIOS firmware-interface magics only. Values copied
; byte-for-byte from the literals they replace.
; ============================================================================
%ifndef BIOS_BOOT_INC
%define BIOS_BOOT_INC

; --- INT 15h, EAX=E820h memory map (ACPI §15 "System Address Map Interfaces")
E820_FN               equ 0x0000E820    ; EAX function selector for the call
E820_SMAP_SIG         equ 0x534D4150    ; "SMAP" magic in EDX (in) / EAX (out)
E820_ENTRY_SIZE       equ 24            ; bytes per address-range descriptor

; --- VESA BIOS Extensions (VBE 3.0 §4.1 "Function 00h - Return Controller Info")
VBE2_SIGNATURE        equ 0x32454256    ; "VBE2" request signature written to the
                                        ; VbeInfoBlock before INT 10h AX=4F00h

; --- Long-mode entry MSR (set EFER.LME/NXE before the PM->LM switch) ---
; IA32_EFER selector for RDMSR/WRMSR. SDM Vol.4 Table 2-2 (MSR C000_0080h).
IA32_EFER_MSR_BIOS    equ 0xC0000080

%endif ; BIOS_BOOT_INC
