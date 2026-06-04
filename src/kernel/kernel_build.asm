; ============================================================================
; NexusOS v3.0 - Monolithic Kernel Build Wrapper
; Combines all kernel components into a single binary
; ============================================================================
[bits 64]
; Pull KERNEL_LOAD_ADDR in early so [org] can use it. boot_memory.inc is guarded
; against re-inclusion (BOOT_MEMORY_INC), so downstream includes that pull it
; via constants.inc are unaffected.
%include "boot_memory.inc"
[org KERNEL_LOAD_ADDR]

; Define macros to ignore extern/global directives in included files
; Using 1-* allows the macro to ignore any number of arguments (comma separated)
%ifmacro extern 1-*
%unmacro extern 1-*
%endif
%macro extern 1-*
%endmacro

%ifmacro global 1-*
%unmacro global 1-*
%endif
%macro global 1-*
%endmacro

%include "build/sig_hashes.inc"

; --- Core Kernel Entry Point (MUST BE FIRST) ---
section .text
%include "src/kernel/core/entry.asm"
%include "src/kernel/core/core_runtime_state.asm"
section .text
%include "build/nxh/kernel_console.asm"
section .text
%include "build/nxh/context_menu.asm"
section .text
%include "build/nxh/kernel_lifecycle.asm"
section .text
%include "build/nxh/serial_poll.asm"
section .text
%include "build/nxh/input_dispatch.asm"
section .text
%include "build/nxh/frame_present.asm"
; NexusHLK: former main-loop and diagnostic modules. Keep these directly after
; core_runtime_state.asm and before measured_boot.asm so the moved code stays in
; the early kernel text span [_start, _kernel_text_end).
section .text
%include "build/nxh/serial_diag.asm"
; Boot/serial diagnostics, debug overlay, CPU accounting, serial console, and
; real-mode boot diagnostics are split into NexusHLK owner modules and compiled
; by nxhc.py --target kernel.
section .text
%include "build/nxh/boot_diag.asm"
section .text
%include "build/nxh/debug_overlay.asm"
section .text
%include "build/nxh/cpu_acct.asm"
section .text
%include "build/nxh/serial_console.asm"
section .text
%include "build/nxh/real_boot_diag.asm"
section .text
%include "build/nxh/real_boot_diag_core.asm"
section .text
%include "build/nxh/real_boot_diag_fbperf.asm"
section .text
%include "build/nxh/real_boot_diag_legacy.asm"
section .text
%include "build/nxh/real_boot_diag_gfx.asm"
section .text
%include "src/kernel/core/measured_boot.asm"
section .text
%include "src/kernel/core/nk_monitor.asm"
section .text
%include "src/kernel/core/kernel_lockdown.asm"
section .text
%include "src/kernel/core/security_status.asm"
section .text
%include "src/kernel/core/klog.asm"
section .text
%include "src/kernel/core/idt.asm"
section .text
%include "src/kernel/core/isr.asm"
%ifdef ENABLE_TRACE
section .text
%include "src/kernel/core/trace.asm"
%endif
section .text
%include "src/kernel/core/memory.asm"
section .text
%include "src/kernel/core/pic.asm"
section .text
%include "src/kernel/core/pit.asm"
section .text
%include "src/kernel/core/tss.asm"
section .text
%include "src/kernel/core/perfdiag.asm"
section .text
%include "src/boot/gdt.asm"
section .text
%include "src/kernel/proc/usermode.asm"
section .text
%include "src/kernel/proc/process.asm"
section .text
%include "src/kernel/proc/syscall.asm"
section .text
%include "src/kernel/proc/workqueue.asm"

; --- Network stack ---
section .text
%include "src/kernel/net/eth.asm"
section .text
%include "src/kernel/net/ip.asm"
section .text
%include "src/kernel/net/arp.asm"
section .text
%include "src/kernel/net/dhcp.asm"
section .text
%include "src/kernel/net/udp.asm"
section .text
%include "src/kernel/net/dns.asm"
section .text
%include "src/kernel/net/icmp.asm"
section .text
%include "src/kernel/net/tcp.asm"

; --- ACPI & APIC Core ---
section .text
%include "src/kernel/arch/rsdp.asm"
section .text
%include "src/kernel/arch/acpi.asm"
section .text
%include "src/kernel/arch/madt.asm"
section .text
%include "src/kernel/arch/aml_parser.asm"
section .text
%include "src/kernel/arch/apic.asm"
section .text
%include "src/kernel/arch/ioapic.asm"

; --- Drivers ---
section .text
%include "src/kernel/drivers/acpi_pci.asm"
section .text
%include "src/kernel/drivers/acpi_ec.asm"
section .text
%include "src/kernel/drivers/display.asm"
section .text
%include "src/kernel/drivers/fbperf.asm"
section .text
%include "src/kernel/drivers/keyboard.asm"
section .text
%include "src/kernel/drivers/mouse.asm"
section .text
%include "src/kernel/drivers/ramdisk.asm"
section .text
%include "src/kernel/drivers/ata.asm"
section .text
%include "src/kernel/drivers/pci.asm"
section .text
%include "src/kernel/drivers/amd_display.asm"
section .text
; AMD DCN/DMUB and GFX11 bring-up subsystems retired 2026-05-26.
; Source preserved under deprecated/780M_IGPU/. See deprecated/README.md
; for the deprecation policy. Do NOT add -dNEXUS_DIAG_LEGACY or
; -dNEXUS_GFX_BRINGUP to any build — the retired gated source
; references symbols that no longer link in the active tree.
%include "src/kernel/drivers/rtl8139.asm"
section .text
%include "src/kernel/drivers/xhci.asm"
section .text
%include "src/kernel/drivers/usb_hid.asm"
section .text
%include "src/kernel/drivers/rtl8156.asm"
section .text
%include "src/kernel/net/nic.asm"
section .text
%include "src/kernel/drivers/driver_debug.asm"
section .text
%include "src/kernel/drivers/spi.asm"
section .text
%include "src/kernel/drivers/spi_hid.asm"
section .text
%include "src/kernel/drivers/i2c_hid.asm"
section .text
%include "src/kernel/drivers/hid_parser.asm"
section .text
%include "src/kernel/drivers/battery.asm"

; --- Filesystem ---
section .text
%include "src/kernel/fs/fat16.asm"

; --- GUI System ---
section .text
%include "src/kernel/gui/resources.asm"
section .text
%include "src/kernel/gui/render.asm"
section .text
%include "src/kernel/gui/window.asm"
section .text
%include "src/kernel/gui/taskbar.asm"
section .text
%include "src/kernel/gui/desktop.asm"
section .text
%include "src/kernel/gui/cursor.asm"
section .text
%include "src/kernel/gui/boot_anim.asm"

; --- Built-in User Apps ---
section .text
%include "src/user/apps.asm"

; --- Libraries ---
section .text
%include "src/kernel/lib/string.asm"
%include "src/kernel/lib/font.asm"
%include "src/kernel/lib/math.asm"
%include "src/kernel/lib/xml.asm"

; --- Generated Signature Registry ---
%ifdef ENABLE_SIG_SECTION
%include "build/sig_registry.inc"
%endif

; --- Helper Wrappers ---
fn_memcpy_wrapper:
    jmp fn_memcpy
fn_memset_wrapper:
    jmp fn_memset
fn_strlen_wrapper:
    jmp fn_strlen

; Resolve symbols used by other modules
memcpy equ fn_memcpy
memset equ fn_memset
strlen equ fn_strlen

; End-of-text marker. NASM `-f bin` concatenates section CONTENT by name in the
; order [.text | .data | .rodata | .bss] regardless of include order, so every
; `section .text` block above aggregates ahead of all .data/.rodata. This label
; therefore sits at the top of the kernel code+helper region: [_start ..
; _kernel_text_end) is exactly the executable kernel image (no writable .data).
; Consumers:
;   - measured_boot.asm hashes this range as "the kernel code" stage.
;   - kernel_lockdown.asm marks this range read-only at PT level after init
;     (security_todo.md §9 "read-only kernel after init"). Writable .data lives
;     past this label, so locking [_start, _kernel_text_end) cannot fault a
;     legitimate global write.
section .text
global _kernel_text_end
_kernel_text_end:

; --- BSS Section ---
section .bss
alignb 16
_bss_start:
; NASM aggregates sections, so all .bss from included files will end up here.
_bss_end:
