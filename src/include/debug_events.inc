%ifndef DEBUG_EVENTS_INC
%define DEBUG_EVENTS_INC

; Structured kernel forensic events.
;
; Use these directly at the code site that owns the fact:
;   DBG_EVT EVT_CALLBACK_DISPATCH, r15, rdi, rsi, rdx, rcx, 0, 0
;   DBG_EVT_IMPORTANT EVT_PANIC, r15, rdi, rsi, rdx, r10, 0, 0
;
; DBG_EVT is debug-build only. DBG_EVT_IMPORTANT is kept in release builds too.
; Both are one-line declarations with typed event ids; there is no side manifest
; to keep in sync and no serial string to grep for later.

DBG_EVT_RECORDS       equ 256
DBG_EVT_MASK          equ (DBG_EVT_RECORDS - 1)
DBG_EVT_RECORD_SIZE   equ 80

DBG_EVT_SEQ           equ 0
DBG_EVT_TSC           equ 8
DBG_EVT_ID            equ 16
DBG_EVT_SLOT          equ 24
DBG_EVT_A0            equ 32
DBG_EVT_A1            equ 40
DBG_EVT_A2            equ 48
DBG_EVT_A3            equ 56
DBG_EVT_A4            equ 64
DBG_EVT_A5            equ 72

; Event ids. Keep these four-byte ASCII where practical so dumps are readable.
EVT_PANIC             equ 0x50414E43      ; PANC
EVT_CPI_SIGN          equ 0x43504947      ; CPIG
EVT_CPI_VERIFY_FAIL   equ 0x43504956      ; CPIV
EVT_CALLBACK_DISPATCH equ 0x43424B44      ; CBKD
EVT_CALLBACK_RETURN   equ 0x43424B52      ; CBKR
EVT_APP_DONE          equ 0x41444F4E      ; ADON
EVT_WX_HASH_FAIL      equ 0x57435848      ; WCXH
EVT_FOCUS_CHANGE      equ 0x464F4353      ; FOCS
EVT_INPUT_ROUTE       equ 0x494E5054      ; INPT
EVT_SYSCALL_ENTER     equ 0x53594345      ; SYCE
EVT_SYSCALL_EXIT      equ 0x53594358      ; SYCX
; No-progress / spin watchdog: a slot repeated the same syscall with identical
; args SC_PROGRESS_LIMIT times in a row without making progress. a0=syscall num,
; a1=arg0, a2=arg1, a3=faulting user RIP, a4=repeat count.
EVT_NOPROGRESS        equ 0x4E4F5052      ; NOPR

; Notepad-open instrumentation (debug builds only). The "opens blank / white
; window only sometimes" symptom is a launch-ordering race: a window is
; drawable the instant wm_create_window_ex returns, but its capability manifest
; (WF_MANIFEST_OK) and L3 slot seed land one step later. These events stamp each
; milestone with a TSC so the dump (DEVT) shows the interleaving that produced a
; blank frame. See .launch_notepad / app_seed_notepad_slot / sc_record_strike /
; window_draw .dispatch_user_draw.
EVT_NP_LAUNCH         equ 0x4E504C41      ; NPLA  launch entry
EVT_NP_WINCREATE      equ 0x4E505743      ; NPWC  wm_create_window_ex returned
EVT_NP_MANIFEST       equ 0x4E504D46      ; NPMF  manifest applied (sandbox on)
EVT_NP_SEED           equ 0x4E505344      ; NPSD  L3 slot seeded
EVT_NP_HANDLERS       equ 0x4E504844      ; NPHD  click/key handlers installed
EVT_NP_DRAW           equ 0x4E504452      ; NPDR  draw callback dispatched
EVT_NP_STRIKE_GAP     equ 0x4E505347      ; NPSG  draw denied before sandbox

%ifndef RELEASE_BUILD
%define ENABLE_DBG_EVT_FULL
%endif

; DBG_EVT6 id, ctx, a0, a1, a2, a3
;
; Debug-build-only thin wrapper over dbg_event_emit6 (core/debug_events.asm),
; which preserves every register. Use this from kernel-context asm sites that
; already have live values in rdi/rsi/rdx/rcx/r8/r9 - the macro spills and
; reloads the six arg registers around the call, and loads rdi last so an
; operand may safely reference one of the other arg registers. Pass operands as
; immediates or non-arg registers (rax/rbx/r10-r15) to avoid ordering surprises.
%macro DBG_EVT6 6
%ifndef RELEASE_BUILD
    push rdi
    push rsi
    push rdx
    push rcx
    push r8
    push r9
    mov r9, %6
    mov r8, %5
    mov rcx, %4
    mov rdx, %3
    mov rsi, %2
    mov rdi, %1
    call dbg_event_emit6
    pop r9
    pop r8
    pop rcx
    pop rdx
    pop rsi
    pop rdi
%endif
%endmacro

%macro DBG_EVT_STORE 8
    push r11
    mov r11, %8
    push r11
    mov r11, %7
    push r11
    mov r11, %6
    push r11
    mov r11, %5
    push r11
    mov r11, %4
    push r11
    mov r11, %3
    push r11
    mov r11, %2
    push r11
    mov r11, %1
    push r11
    push rax
    push rbx
    push rcx
    push rdx
    push r10
    mov eax, 1
    lock xadd qword [rel dbg_evt_head], rax
    mov rbx, rax
    mov r10, rax
    and r10, DBG_EVT_MASK
    imul r10, DBG_EVT_RECORD_SIZE
    lea r10, [abs dbg_evt_ring + r10]
    mov [r10 + DBG_EVT_SEQ], rbx
    rdtsc
    shl rdx, 32
    or rax, rdx
    mov [r10 + DBG_EVT_TSC], rax
    mov r11, [rsp + 40]
    mov [r10 + DBG_EVT_ID], r11
    mov r11, [rsp + 48]
    mov [r10 + DBG_EVT_SLOT], r11
    mov r11, [rsp + 56]
    mov [r10 + DBG_EVT_A0], r11
    mov r11, [rsp + 64]
    mov [r10 + DBG_EVT_A1], r11
    mov r11, [rsp + 72]
    mov [r10 + DBG_EVT_A2], r11
    mov r11, [rsp + 80]
    mov [r10 + DBG_EVT_A3], r11
    mov r11, [rsp + 88]
    mov [r10 + DBG_EVT_A4], r11
    mov r11, [rsp + 96]
    mov [r10 + DBG_EVT_A5], r11
    pop r10
    pop rdx
    pop rcx
    pop rbx
    pop rax
    add rsp, 64
    pop r11
%endmacro

%macro DBG_EVT 8
%ifdef ENABLE_DBG_EVT_FULL
    DBG_EVT_STORE %1, %2, %3, %4, %5, %6, %7, %8
%endif
%endmacro

%macro DBG_EVT_IMPORTANT 8
    DBG_EVT_STORE %1, %2, %3, %4, %5, %6, %7, %8
%endmacro

%endif ; DEBUG_EVENTS_INC
