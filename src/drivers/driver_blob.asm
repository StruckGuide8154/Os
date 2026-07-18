; ============================================================================
; Dedicated ring-3 driver blobs (Track 8).
;
; Each driver package is intentionally separate from APPS.BIN: broker syscall
; numbers are raw u32 values (some exceed 255), the executable window is small,
; and the fixed [1 MiB, 1.25 MiB) DMA mapping remains writable+NX. KERNEL.ENV
; covers the embedded source bytes; l3_copy_driver_blob*_to_slot installs a
; private copy per driver slot.
;
; Every package stays in the single non-kernel-text `.driverblob` section.
; gritc emits `<app>_driver_code_end` at the page-aligned W^X boundary of each
; package, aliased here to the per-blob
; `driverN_blob_code_end` scalar the slot installer consumes. A package's
; done-trampoline must be the first bytes of its own blob-relative frame so the
; callback stack unwind stays per-slot correct (usermode_callbacks.ghl keys the
; trampoline offset off the slot's blob kind).
; ============================================================================

; ---------------------------------------------------------------------------
; Blob 1 (slot kind 1): virtio-net NIC driver.
; ---------------------------------------------------------------------------
[section .driverblob follows=.appdata align=4096]
global driver_blob_start
driver_blob_start:

; The callback stack returns here. The driver slot uses identity syscall
; numbering, so this must stay a raw SYS_APP_DONE immediate (10).
global driver_blob_done_trampoline
driver_blob_done_trampoline:
    mov eax, 10
    syscall
    ud2

%define DISABLE_FN_RUNTIME_TRACE
%include "build/ghl/virtio_net.asm"
%undef DISABLE_FN_RUNTIME_TRACE

driver_blob_code_end equ app_hl_virtio_net_driver_code_end

; gritc emits a page-aligned code-end boundary before generated state, all
; within this contiguous section so the copy bounds are link-time scalars.
global driver_blob_end
driver_blob_end:

%if (driver_blob_end - driver_blob_start) >= L3_SLOT_DMA_OFF
%error "ring-3 driver blob reaches the fixed DMA VA window"
%endif
%if ((driver_blob_code_end - driver_blob_start) & 0xFFF) != 0
%error "ring-3 driver W^X code boundary must be page-aligned"
%endif
%if (driver_blob_code_end - driver_blob_start) > (driver_blob_end - driver_blob_start)
%error "ring-3 driver code boundary lies beyond the blob"
%endif

; ---------------------------------------------------------------------------
; Blob 2 (slot kind 2): ACPI-EC battery driver (PIO-only, no DMA window used).
; ---------------------------------------------------------------------------
align 4096
global driver2_blob_start
driver2_blob_start:

global driver2_blob_done_trampoline
driver2_blob_done_trampoline:
    mov eax, 10
    syscall
    ud2

%define DISABLE_FN_RUNTIME_TRACE
%include "build/ghl/battery.asm"
%undef DISABLE_FN_RUNTIME_TRACE

driver2_blob_code_end equ app_hl_battery_driver_code_end

global driver2_blob_end
driver2_blob_end:

%if (driver2_blob_end - driver2_blob_start) >= L3_SLOT_DMA_OFF
%error "ring-3 driver blob 2 reaches the fixed DMA VA window"
%endif
%if ((driver2_blob_code_end - driver2_blob_start) & 0xFFF) != 0
%error "ring-3 driver blob 2 W^X code boundary must be page-aligned"
%endif
%if (driver2_blob_code_end - driver2_blob_start) > (driver2_blob_end - driver2_blob_start)
%error "ring-3 driver blob 2 code boundary lies beyond the blob"
%endif

section .text
