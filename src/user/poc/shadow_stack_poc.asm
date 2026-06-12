; ============================================================================
; Shadow-stack PoC for the kernel-side syscall-path return-address guard.
;
; WHY THIS IS KERNEL-SIDE (no ring-3 code here)
;   The threat the shadow stack defends against is corruption of a *kernel*
;   return address saved on the per-slot syscall stack - e.g. a stack overflow
;   inside a validator that runs on that stack. A ring-3 app cannot write to
;   another ring's stack, so the corruption (and therefore the PoC that
;   demonstrates the catch) necessarily lives in the kernel. The user-side
;   analogue - overflowing the *user* stack into its guard page - is the
;   separate stack_overflow_poc.asm in this directory.
;
; HOW THE TRIP WORKS  (src/kernel/proc/syscall.asm, %ifdef ENABLE_SHADOW_STACK_POC)
;   shadow_stack_poc_run, called once from kmain after the syscall-stack page
;   tables are installed:
;     1. switches RSP onto slot 0's syscall stack (so rsp ^ 0x2000 lands in the
;        parallel shadow page - see src/include/shadow_stack.inc);
;     2. calls shadow_poc_trip, a KPROLOGUE/KEPILOGUE-protected frame;
;     3. shadow_poc_trip overwrites its own saved return address with
;        0xDEADBEEFCAFEBABE *after* KPROLOGUE has already mirrored the true
;        return address into the shadow page;
;     4. KEPILOGUE re-derives the shadow slot, sees observed != mirror, and
;        jumps to kernel_panic_shadow.
;
; BUILD + RUN
;   pwsh scripts/build/build_uefi.ps1 -ShadowStackPoc
;   pwsh scripts/run/run_uefi.ps1 -Headless -NoPassthrough
;   (then inspect build/serial_full.log)
;
; EXPECTED SERIAL OUTPUT
;   POCS                                  harness started
;   SHADOW DEADBEEFCAFEBABE ! <true_ret>  KEPILOGUE caught the corruption,
;                                         then the CPU halts  <-- pass
;
; REGRESSION SIGNAL
;   POCF                                  the smashed return address was NOT
;                                         detected - the shadow stack is broken.
;
; Without the shadow stack the corrupted return address would simply be popped
; by RET and the CPU would transfer control to 0xDEADBEEFCAFEBABE.
; ============================================================================

bits 64
; Intentionally empty: the proof harness is the kernel stub described above.
; This file is reference documentation, mirroring stack_overflow_poc.asm.
