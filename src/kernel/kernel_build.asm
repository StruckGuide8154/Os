; ============================================================================
; Grit v3.0 - Monolithic Kernel Build Wrapper
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
%include "build/ghl/kernel_console.asm"
section .text
%include "build/ghl/context_menu.asm"
section .text
%include "build/ghl/kernel_lifecycle.asm"
section .text
%include "build/ghl/serial_poll.asm"
section .text
%include "build/ghl/input_dispatch.asm"
section .text
%include "build/ghl/frame_present.asm"
section .text
%include "build/ghl/frame_pacing.asm"
; GritHLK: former main-loop and diagnostic modules. Keep these directly after
; core_runtime_state.asm and before crypto.ghl so the moved code stays in
; the early kernel text span [_start, _kernel_text_end).
section .text
%include "build/ghl/serial_diag.asm"
; Boot/serial diagnostics, debug overlay, CPU accounting, serial console, and
; real-mode boot diagnostics are split into GritHLK owner modules and compiled
; by gritc.py --target kernel.
section .text
%include "build/ghl/boot_diag.asm"
section .text
%include "build/ghl/boot_timing.asm"
section .text
%include "build/ghl/boot_features.asm"
%ifndef RELEASE_BUILD
section .text
%include "build/ghl/debug_overlay.asm"
%endif
section .text
%include "build/ghl/cpu_acct.asm"
section .text
%include "build/ghl/serial_console.asm"
section .text
%include "build/ghl/crypto.asm"
section .text
; Track 4 Part A: RAM-only / volatile secret scrubbing (wipe-on-shutdown / panic
; / tamper). Provides nx_volatile_panic_scrub (called from kernel_panic_canary /
; kernel_panic_shadow) and nx_volatile_wipe_halt (serial 'w' clean-exit wipe).
%include "build/ghl/ram_volatile.asm"
section .text
; Track 4 Part B items 2+4: encrypt-at-rest-in-RAM (nx_atrest_xcrypt + the
; decrypt-into-window helpers) and whiten-kernel-secrets-at-rest (nx_secret_mask
; + nx_mask_secret/nx_unmask_secret). %included after ram_volatile so its
; nx_mem_key / nx_splitmix64 labels resolve as same-unit symbols.
%include "build/ghl/ram_atrest.asm"
section .text
; Track 2 signed-envelope enforcement: structural policy kernel
; (security_envelope_*), semantic policy kernel (security_artifact_*), and the
; in-kernel byte-walking reader (envelope_verify) that composes them. The
; policy kernels are the SAME sources the host fixture gate compiles
; (src/tools/security), so the in-OS verifier and the checked contract cannot
; drift apart.
%include "build/ghl/signed_envelope.asm"
section .text
%include "build/ghl/signed_artifact_check.asm"
section .text
%include "build/ghl/threshold_check.asm"
section .text
%include "build/ghl/envelope_reader.asm"
section .text
%include "build/ghl/ed25519_check.asm"
section .text
; CMOS RTC wallclock -> unix seconds (verifier-clock source for the gate).
%include "build/ghl/rtc_time.asm"
section .text
; Persistent anti-rollback floors: per-class monotonic minimums in a reserved
; data.img sector, loaded before any admission and ratcheted by accepted
; envelopes (fail-soft to the build-time floors without ATA media).
%include "build/ghl/floor_store.asm"
section .text
; Track 2 admission gate: binds envelope_verify_signed into the boot-chain
; (SYSSIG.ENV, fail-closed) + update-path (KUPDATE.ENV) call sites, with the
; verified-artifact hash cache in front of the Ed25519 crypto.
%include "build/ghl/envelope_gate.asm"
section .text
%include "src/kernel/core/nk_monitor.asm"
section .text
%include "src/kernel/core/kernel_lockdown.asm"
section .text
%include "src/kernel/core/security_status.asm"
section .text
%include "src/kernel/core/klog.asm"
section .text
%include "src/kernel/core/debug_events.asm"
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
; GritHLK (zero-asm) ring-3 callback / app-done trampoline path. Ported from
; src/kernel/proc/usermode_callbacks.inc + l3_install_app_done_trampoline (was in
; usermode_integrity.inc); those .inc definitions are now removed to avoid a
; duplicate-symbol clash. Defines call_app_l3, call_app_l3_packed,
; call_app_l3_return, call_app_l3_app_done, l3_install_app_done_trampoline,
; test_usermode_proc. Same single-TU: l3_runtime_ptr / l3_slot_base /
; l3_translate_target / l3_copy_app_blob_to_slot / l3_apply_slot_isolation /
; l3_apply_wx_policy / l3_user_stack_top resolve as forward refs.
%include "build/ghl/usermode_callbacks.asm"
section .text
%include "src/kernel/proc/process.asm"
section .text
; GritHLK Stage 2a: syscall LEAF validators/support (zero-asm). Must precede
; syscall.asm so its globals (sc_get_slot_bounds, sc_range_in_bounds,
; sc_validate_user_range/_io_range, sc_validate_callback_target, dbg_wc_hex64,
; dbg_wmcreate_log) are defined before the dispatcher/handler .inc files use them.
%include "build/ghl/syscall_validate.asm"
section .text
; GritHLK Stage 2b: syscall HMAC / cap-mask security LEAF helpers (zero-asm).
; Must precede syscall.asm so its globals (cpi_sign_callback, cpi_verify_callback,
; cap_mask_sign, cap_mask_store, slot_cap_hmac_init) are defined before the
; dispatcher/handler/security .inc files (and kernel_main) reference them.
%include "build/ghl/syscall_secure.asm"
section .text
%include "src/kernel/proc/syscall.asm"
; GritHLK syscall data section (Stage 1 of docs/ghlk-syscall-rearchitecture.md):
; the unconditional, const-sized syscall data symbols migrated out of
; syscall_data.inc. Pure `section .data` (no .text); NASM -f bin aggregates it
; into the writable .data region past _kernel_text_end regardless of position.
section .data
%include "build/ghl/syscall_data.asm"
section .text
%include "src/kernel/proc/workqueue.asm"

; --- Network stack ---
section .text
%include "build/ghl/eth.asm"
section .text
%include "src/kernel/net/ip.asm"
section .text
%include "src/kernel/net/arp.asm"
section .text
%include "src/kernel/net/dhcp.asm"
section .text
%include "src/kernel/net/udp.asm"
section .text
%include "build/ghl/dns.asm"
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
; for the deprecation policy. Do NOT add -dGRIT_DIAG_LEGACY or
; -dGRIT_GFX_BRINGUP to any build - the retired gated source
; references symbols that no longer link in the active tree.
%include "src/kernel/drivers/rtl8139.asm"
section .text
%include "src/kernel/drivers/xhci.asm"
section .text
; GritHLK: USB HID LEAF helpers (zero-asm). Must precede usb_hid.asm so its
; globals (usb_log_ch, usb_log_str, usb_log_crlf, usb_log_hex_nib,
; usb_hid_flush_log, usb_find_endpoint, usb_try_known_mouse_endpoint) are
; defined before usb_hid.asm's remaining asm references them. The data symbols
; they touch are still defined in usb_hid.asm's section .data (one NASM unit).
%include "build/ghl/usb_hid_helpers.asm"
section .text
%include "src/kernel/drivers/usb_hid.asm"
section .text
; GritHLK (zero-asm) DHCP/ARP control path - must precede rtl8156.asm so the
; single NASM TU resolves these globals as forward refs (see each module header).
%include "build/ghl/rtl8156_dhcp_build.asm"
section .text
%include "build/ghl/rtl8156_arp.asm"
section .text
%include "build/ghl/rtl8156_dhcp_parse.asm"
section .text
%include "build/ghl/rtl8156_dhcp_sm.asm"
section .text
%include "src/kernel/drivers/rtl8156.asm"
section .text
%include "src/kernel/net/nic.asm"
section .text
; net_dhcp_configure / net_dhcp_start ported out of nic.asm to zero-asm GHLK.
%include "build/ghl/net_dhcp_dispatch.asm"
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
; GritHLK (zero-asm) window-manager leaf helpers - included BEFORE window.asm
; so wm_get_window_at / wm_cb_intern / wm_cb_resolve / wm_bg_* /
; wm_mark_outline_dirty symbols resolve for window.asm's callers.
%include "build/ghl/wm_helpers.asm"
section .text
%include "src/kernel/gui/window.asm"
section .text
%include "src/kernel/gui/taskbar.asm"
section .text
%include "src/kernel/gui/desktop.asm"
section .text
; GritHLK mouse cursor rendering (zero-asm; compiled with --forbid-asm).
%include "build/ghl/cursor.asm"
section .text
; GritHLK boot animation player (zero-asm; compiled with --forbid-asm).
%include "build/ghl/boot_anim.asm"

; --- Built-in User Apps ---
section .text
%include "src/user/apps.asm"

; --- Libraries ---
section .text
; GritHLK (zero-asm) string/memory utilities (ported from lib/string.asm).
%include "build/ghl/string.asm"
; GritHLK (zero-asm) VGA 8x16 bitmap font table (ported from lib/font.asm).
%include "build/ghl/font.asm"
; GritHLK (zero-asm) math/geometry leaf helpers (ported from lib/math.asm).
%include "build/ghl/math.asm"
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
;   - crypto.ghl hashes this range as the measured kernel-code stage.
;   - kernel_lockdown.asm marks this range read-only at PT level after init
;     (security_todo.md §9 "read-only kernel after init"). Writable .data lives
;     past this label, so locking [_start, _kernel_text_end) cannot fault a
;     legitimate global write.
section .text
global _kernel_text_end
_kernel_text_end:

; --- BSS Section ---
; NASM aggregates sections, so all .bss from included files end up between
; _bss_start (declared first, in entry.asm) and _bss_end here. _start clears
; this whole span so a KASLR-slid kernel never runs on uninitialized BSS.
section .bss
alignb 16                      ; keep _bss_end - _bss_start a multiple of 8 (16)
_bss_end:
