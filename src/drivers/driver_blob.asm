; ============================================================================
; Dedicated ring-3 driver blob.
;
; This blob is intentionally separate from APPS.BIN: broker syscall numbers are
; raw u32 values (some exceed 255), its executable window is small, and the
; fixed [1 MiB, 1.25 MiB) DMA mapping remains writable+NX. KERNEL.ENV covers the
; embedded source bytes; l3_copy_driver_blob_to_slot installs a private copy.
; ============================================================================

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

; gritc emits a page-aligned driver_blob_code_end before generated state, all
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

section .text
