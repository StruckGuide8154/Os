; ============================================================================
; GritOS v3.0 - USB XHCI Host Controller Driver
; PCI discovery, controller init, ring management, port/device enumeration
; ============================================================================
bits 64

%include "constants.inc"

extern pci_read_conf_dword
extern pci_write_conf_dword
extern tick_count
extern debug_print
extern usb_hid_port_owned

; --- MMIO bounds gate (security_todo.md §8) ---------------------------------
; The xHCI BAR is registered as MMIO_DRV_XHCI by mmio_drv_caps_init once the
; probe resolves xhci_mmio_base. XHCI_MMIO_ASSERT proves a register access (via
; xhci_op_base/rt_base/db_base, all offsets inside the same BAR) stays in that
; window before issuing it. mmio_bounds_assert preserves caller regs but reads
; rdi/rsi/edx; the macro saves/restores those three so surrounding code is
; unperturbed. Skipped when base==0 (no controller) so a BIOS/no-USB boot that
; never registers a region does not spuriously panic on a stray cold path.
extern mmio_bounds_assert
%macro XHCI_MMIO_ASSERT 2          ; %1 = access addr/base reg, %2 = window (legacy, unused)
    push rdi
    push rsi
    push rdx
    mov rdi, %1
    test rdi, rdi
    jz %%skip                       ; base unresolved - nothing registered yet
    ; Probe an 8-byte access AT THE BASE, not the whole window: xhci_op_base/
    ; rt_base/db_base are OFFSETS inside the BAR (base+caps_len), so asserting a
    ; full-MMIO_XHCI_WINDOW span from here overshoots the registered region end
    ; by the caps length and false-panics. An 8-byte probe validates the base
    ; pointer lies inside the registered BAR (catches a wild/corrupt base); the
    ; driver's per-register offsets are all < window, so an in-region base means
    ; in-region accesses. %2 retained for call-site compatibility (documentation).
    mov esi, 8
    mov edx, MMIO_DRV_XHCI
    call mmio_bounds_assert
%%skip:
    pop rdx
    pop rsi
    pop rdi
%endmacro

section .text

%include "src/kernel/drivers/xhci_dbglog.inc"
%include "src/kernel/drivers/xhci_init.inc"
%include "src/kernel/drivers/xhci_rings.inc"
%include "src/kernel/drivers/xhci_ports.inc"
%include "src/kernel/drivers/xhci_slots.inc"
%include "src/kernel/drivers/xhci_trb.inc"
%include "src/kernel/drivers/xhci_data.inc"
