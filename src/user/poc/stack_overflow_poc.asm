; ============================================================================
; Stack-overflow PoC for per-slot user-stack guard pages.
;
; Manual verification (not wired into the build):
;   1. Temporarily replace an existing click handler's body with a call into
;      `stack_overflow_poc_click` (or rename the global to match a callback
;      symbol expected by the dispatcher).
;   2. Boot under QEMU with serial logging enabled.
;   3. Trigger the handler from the app's window.
;
; Expected:
;   Recursion walks RSP downward in 256-byte frames. After ~64 frames RSP
;   crosses below the slot's user stack bottom (0x1FBDF0 within the slot)
;   into the guard page at offset 0x1FA000. The CPU raises #PF, isr.asm's
;   fast path matches the address, logs "STKG=<slot>" to serial, and aborts
;   the slot via call_app_l3_return - neighbour slot data is intact.
;
; Without the guard: the recursion would silently overwrite whatever sits
; below the user stack in the slot (the app's data/code region), corrupting
; it before any visible fault.
;
; This guards the *user* stack. The kernel-side analogue - protecting return
; addresses saved on the per-slot *syscall* stack - now exists as a parallel
; shadow stack (src/include/shadow_stack.inc); its proof harness is
; shadow_stack_poc.asm in this directory.
; ============================================================================

bits 64

%include "grit_app.inc"

global stack_overflow_poc_click
stack_overflow_poc_click:
    ; Each frame moves RSP down by 256 bytes (sub) + 8 (call) = 264 bytes.
    ; 16 KiB / 264 ≈ 62 frames before crossing into the guard page.
    sub rsp, 256
    call stack_overflow_poc_click
    add rsp, 256
    ret
