; ============================================================================
; NexusOS v2.0 - Legacy standalone UEFI graphical boot image
;
; Owner: legacy UEFI boot image maintainers
;
; This file is intentionally an ordered include manifest. The active UEFI
; build path uses src/boot/uefi_loader.asm; this legacy PE/COFF image is kept
; assembleable for audit and maintenance. Include order below is boot order
; and preserves the original flat binary layout.
; ============================================================================

%include "src/boot/boot_uefi_defs.inc"

; --- PE/COFF image header and entry path -------------------------------------
%include "src/boot/boot_uefi_pe_entry.inc"

; --- Firmware protocol discovery ---------------------------------------------
%include "src/boot/boot_uefi_protocols.inc"

; --- Cursor and mouse interaction --------------------------------------------
%include "src/boot/boot_uefi_cursor.inc"

; --- GOP drawing primitives --------------------------------------------------
%include "src/boot/boot_uefi_render.inc"

; --- Desktop UI --------------------------------------------------------------
%include "src/boot/boot_uefi_desktop.inc"

; --- Text shell and commands -------------------------------------------------
%include "src/boot/boot_uefi_shell.inc"

; --- Static assets and state -------------------------------------------------
%include "src/boot/boot_uefi_font.inc"
%include "src/boot/boot_uefi_data.inc"

; --- Final image layout records ---------------------------------------------
%include "src/boot/boot_uefi_image_tail.inc"
