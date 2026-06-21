; ============================================================================
; Grit v3.0 - PIT Timer Driver
; ============================================================================
bits 64
%include "constants.inc"

extern fb_addr, main_loop_stage, main_loop_stage_done, gui_initialized
; Boot-race guard: only 1 once kmain has finished ALL init and entered the main
; loop (core_runtime_state.asm). Gates the slot-integrity scans below so a PIT
; tick can't hash a slot mid-load/mid-perm-rewrite (the intermittent boot
; "CANARY 0 @<hash>" panic). Strictly delays when scanning starts.
extern code_hash_armed
extern scr_pitch_q, scr_width, scr_height
; Per-slot syscall rate-limit token buckets, defined in syscall_data.ghl.
; Refilled once per timer tick (security_todo.md §2).
extern slot_sc_budget
extern slot_gui_budget
; Code-range integrity re-verify (security_todo.md §12), defined in
; usermode.asm. Re-hashes each slot's executable code range against its
; install-time baseline; panics on mismatch. Called on a tick cadence below.
extern l3_code_hash_verify_all
; Behavioral anomaly detector (security_todo.md §11), defined in syscall.asm.
; Scans each live slot's syscall-mix histogram for a deviation from its app
; profile and drives an over-budget slot through the §12 strike path. Called on
; the coarse ANOMALY_SCAN_PERIOD cadence below.
extern sc_anomaly_scan_all

; Re-verify cadence in PIT ticks. MUST be a power of two (masked, not divided).
; PIT_FREQUENCY ticks ≈ 1 s, so 64 ticks re-hashes every code range a few times
; per second - frequent enough to catch a transient W^X breach quickly, coarse
; enough that the per-tick branch is free on the 63/64 ticks it is skipped.
%ifndef CODE_HASH_VERIFY_PERIOD
CODE_HASH_VERIFY_PERIOD equ 64
%endif

section .text
global pit_init
pit_init:
    mov al, 0x36
    out 0x43, al
    mov ax, PIT_DIVISOR
    out 0x40, al
    mov al, ah
    out 0x40, al

    mov qword [tick_count], 0
    mov dword [sub_ticks], 0
    mov dword [time_seconds], 0
    mov dword [time_minutes], 0
    mov dword [time_hours], 12

    call cmos_read_time
    ret

; ----------------------------------------------------------------------------
; cmos_read_time
; Seeds time_seconds/minutes/hours from the CMOS RTC. Handles BCD vs binary
; and 12-hour mode (PM bit 0x80 on hour register). Reads twice and retries
; until two consecutive reads agree, to avoid tearing across an RTC update.
; Clobbers rax, rbx, rcx, rdx, r8.
; ----------------------------------------------------------------------------
cmos_read_time:
    ; Wait until Update-In-Progress clears.
.wait_uip:
    mov al, 0x0A
    out 0x70, al
    in  al, 0x71
    test al, 0x80
    jnz .wait_uip

    ; First read: sec/min/hour into bl/bh/cl
    mov al, 0x00
    out 0x70, al
    in  al, 0x71
    mov bl, al
    mov al, 0x02
    out 0x70, al
    in  al, 0x71
    mov bh, al
    mov al, 0x04
    out 0x70, al
    in  al, 0x71
    mov cl, al

    ; Second read; loop until it matches.
.reread:
    mov al, 0x0A
    out 0x70, al
    in  al, 0x71
    test al, 0x80
    jnz .reread

    mov al, 0x00
    out 0x70, al
    in  al, 0x71
    mov dl, al
    cmp dl, bl
    jne .copy_and_retry

    mov al, 0x02
    out 0x70, al
    in  al, 0x71
    mov dh, al
    cmp dh, bh
    jne .copy_and_retry2

    mov al, 0x04
    out 0x70, al
    in  al, 0x71
    cmp al, cl
    je  .stable

    mov cl, al
    jmp .reread

.copy_and_retry2:
    mov bh, dh
    jmp .reread
.copy_and_retry:
    mov bl, dl
    jmp .reread

.stable:
    ; Read Status Register B to learn format.
    mov al, 0x0B
    out 0x70, al
    in  al, 0x71
    mov r8b, al              ; r8b = status B

    ; Strip PM flag from hour now, remember it.
    xor ch, ch               ; ch = pm_flag (0 or 1)
    test r8b, 0x02           ; bit 1 set => 24-hour
    jnz .h24
    test cl, 0x80
    jz  .no_pm
    and cl, 0x7F
    mov ch, 1
.no_pm:
.h24:
    ; If BCD (bit 2 == 0), convert.
    test r8b, 0x04
    jnz .binary

    ; sec
    mov al, bl
    call bcd_to_bin
    mov bl, al
    ; min
    mov al, bh
    call bcd_to_bin
    mov bh, al
    ; hour
    mov al, cl
    call bcd_to_bin
    mov cl, al

.binary:
    ; Apply PM if 12-hour: hour 12 PM stays 12; 1-11 PM => +12; 12 AM => 0.
    test r8b, 0x02
    jnz .store               ; 24-hour, nothing to do
    cmp cl, 12
    jne .not12
    test ch, ch
    jnz .store               ; 12 PM -> 12
    xor cl, cl               ; 12 AM -> 0
    jmp .store
.not12:
    test ch, ch
    jz .store
    add cl, 12

.store:
    movzx eax, bl
    mov [time_seconds], eax
    movzx eax, bh
    mov [time_minutes], eax
    movzx eax, cl
    mov [time_hours], eax
    ret

; al = BCD byte -> al = binary
bcd_to_bin:
    mov dl, al
    and dl, 0x0F
    shr al, 4
    and al, 0x0F
    mov dh, 10
    mul dh                   ; ax = al * 10
    add al, dl
    ret

global pit_handler
pit_handler:
    push rax
    push rdx
    push rdi
    push rcx

    inc qword [tick_count]

    ; --- Priority manager (Stage 2): quantum bookkeeping ---------------------
    ; Decrement the running process's time-slice each tick; refill by class at 0.
    ; rax/rcx/rdx are saved by the pit_handler prologue, which pm_tick_quantum
    ; relies on. (Defined in process_callbacks.inc, where process_t is in scope.)
    extern pm_tick_quantum
    call pm_tick_quantum

    ; --- Syscall rate-limit refill (security_todo.md §2) ---------------------
    ; Restore every slot's token bucket to SC_BUDGET_PER_TICK. Slots that
    ; drained their budget this tick are throttled (dispatcher denies -1) until
    ; this runs. MAX_WINDOWS is tiny (12) so the unconditional store is cheap;
    ; an idle slot just gets its full bucket back. rax/rcx/rdi are already saved
    ; by the pit_handler prologue.
    lea rdi, [rel slot_sc_budget]
    mov ecx, MAX_WINDOWS
    mov ax, SC_BUDGET_PER_TICK
.sc_budget_refill:
    mov [rdi], ax
    add rdi, 2
    dec ecx
    jnz .sc_budget_refill

    lea rdi, [rel slot_gui_budget]
    mov ecx, MAX_WINDOWS
    mov ax, SC_GUI_BUDGET_PER_TICK
.sc_gui_budget_refill:
    mov [rdi], ax
    add rdi, 2
    dec ecx
    jnz .sc_gui_budget_refill

    ; App-slot integrity work is only meaningful after the GUI/app slots are
    ; initialized. During the boot splash, PIT IRQs are already enabled for
    ; frame pacing; running slot scans that early races partially initialized
    ; app/syscall state and can trip the canary path before kmain reaches K6.
    cmp byte [gui_initialized], 1
    jne .skip_slot_security_scans
    ; Additional boot-race guard (security_todo.md §12): even after
    ; gui_initialized flips at wm_init, kernel_lockdown_ro / nk_protect_page
    ; _tables / the first lazy app loads still run before the main loop. A tick
    ; in that window hashes a slot whose bytes are still settling -> spurious
    ; CANARY panic. code_hash_armed is set once, right before the main loop, so
    ; the scans below stay inert until all boot init is genuinely complete.
    cmp byte [code_hash_armed], 1
    jne .skip_slot_security_scans

    ; --- Code-range integrity re-verify (security_todo.md §12) ---------------
    ; Every CODE_HASH_VERIFY_PERIOD ticks, re-hash each slot's executable code
    ; range and compare against the install-time baseline. A mismatch means an
    ; unintended W landed on a code page (e.g. an undiscovered JIT-alias bug
    ; mutated executable bytes) -> l3_code_hash_verify_all panics fail-closed.
    ; Throttled to a coarse cadence so the per-tick cost stays negligible; the
    ; hash skips the handle-table carve-out, so legit handle writes never trip
    ; it. Done before EOI/clock-advance so a detected violation halts promptly.
    mov eax, [tick_count]                 ; low dword of the 64-bit tick counter
    and eax, CODE_HASH_VERIFY_PERIOD - 1  ; power-of-two cadence mask
    jnz .skip_code_hash_verify
    call l3_code_hash_verify_all
.skip_code_hash_verify:

    ; --- Behavioral anomaly scan (security_todo.md §11) ----------------------
    ; Every ANOMALY_SCAN_PERIOD ticks, scan each live slot's syscall-mix
    ; histogram (built by the always-on trace ring) for a deviation from its
    ; app profile - e.g. a Notepad slot hammering the W^X/JIT-alias surface - and
    ; drive an over-budget slot through the existing §12 strike/kill path. Coarser
    ; than the code-hash cadence and far coarser than the per-tick budget refill,
    ; so the per-tick branch is free on the ticks it is skipped and the detector
    ; never touches the hot dispatch path. rax/rcx/rdi already saved by the
    ; pit_handler prologue; sc_anomaly_scan_all preserves all regs regardless.
    mov eax, [tick_count]
    and eax, ANOMALY_SCAN_PERIOD - 1      ; power-of-two cadence mask
    jnz .skip_anomaly_scan
    call sc_anomaly_scan_all
.skip_anomaly_scan:
.skip_slot_security_scans:

    ; --- HANG DEBUG: write main_loop_stage and stage_done to a known
    ; framebuffer location every PIT tick so we can SEE which call hung even
    ; when the main loop is stuck. Top-left of screen, 4 colored pixel groups:
    ;   group 0 (cyan/black)  : indicates "alive" - flashes each tick
    ;   group 1 (white)       : main_loop_stage value, 4 bits each
    ;   group 2 (yellow)      : main_loop_stage_done value, 4 bits each
    ; Each group is 32px wide (8px per nibble * 4 nibbles) = compact corner band.
    jmp .skip_dbg                ; debug pixel overlay disabled
    mov rdi, [fb_addr]
    test rdi, rdi
    jz .skip_dbg

    ; Group 0: alive flash (32 px). Color alternates per tick.
    mov eax, [tick_count]
    and eax, 1
    jz .blk
    mov eax, 0x0000FFFF              ; cyan
    jmp .fa
.blk:
    mov eax, 0x00000000              ; black
.fa:
    mov rcx, 32
.alive_lp:
    mov [rdi + rcx*4 - 4], eax
    dec rcx
    jnz .alive_lp

    ; Group 1: main_loop_stage as 8 colored pixels at fb+128..fb+156
    ; (each px = 1 bit, white=1 black=0)
    movzx eax, byte [main_loop_stage]
    mov rcx, 8
.stage_lp:
    mov edx, eax
    and edx, 1
    jz .stage_off
    mov dword [rdi + rcx*4 + 128 - 4], 0x00FFFFFF
    jmp .stage_next
.stage_off:
    mov dword [rdi + rcx*4 + 128 - 4], 0x00000000
.stage_next:
    shr eax, 1
    dec rcx
    jnz .stage_lp

    ; Group 2: main_loop_stage_done as 8 colored pixels at fb+192..fb+220
    movzx eax, byte [main_loop_stage_done]
    mov rcx, 8
.done_lp:
    mov edx, eax
    and edx, 1
    jz .done_off
    mov dword [rdi + rcx*4 + 192 - 4], 0x00FFFF00
    jmp .done_next
.done_off:
    mov dword [rdi + rcx*4 + 192 - 4], 0x00000000
.done_next:
    shr eax, 1
    dec rcx
    jnz .done_lp

    ; --- Big visible "last completed stage" block in top-right corner.
    ; 64x64 px solid color encodes main_loop_stage_done. Painted every PIT
    ; tick directly to the front framebuffer, so it persists even when the
    ; main loop has frozen and render_frame stops overpainting. If the loop
    ; is alive, you'll see this block flicker (render_frame keeps repainting
    ; over it between ticks); if it's frozen, the block stays solid and its
    ; color tells you which stage was the last to finish before the hang.
    push r8
    push r9
    push r10
    mov r9, [scr_pitch_q]
    test r9, r9
    jz .blk_done
    mov r10d, [scr_width]
    sub r10d, 72                      ; x = right - 72 (in pixels)
    js .blk_done
    shl r10d, 2                       ; -> bytes (4 bpp)
    movsxd r10, r10d
    ; row 8 from top (avoids overlap with row-0 nibble markers)
    mov r8, r9
    shl r8, 3                         ; pitch * 8
    add r8, r10
    add r8, rdi                       ; r8 = top-left of block in fb

    movzx eax, byte [main_loop_stage_done]
    ; Encode stage_done into a bright distinguishable color.
    ; stage 1 -> dark red, 2 -> red, 3 -> orange, 4 -> yellow, 5 -> green,
    ; 6 -> cyan, 7 -> blue, 8 -> magenta, 9 -> white, 10 -> bright green
    mov edx, eax
    shl edx, 5                        ; *32 = R component
    and edx, 0xE0
    mov ecx, eax
    shl ecx, 12                       ; *4096 = G component (bits 8..15)
    and ecx, 0xE000
    or edx, ecx
    or edx, 0x00303030                ; baseline so block is always visible

    mov r10d, 64                      ; row counter
.blk_row:
    mov rax, r8
    mov ecx, 64                       ; col counter
.blk_col:
    mov [rax], edx
    add rax, 4
    dec ecx
    jnz .blk_col
    add r8, r9
    dec r10d
    jnz .blk_row
.blk_done:
    pop r10
    pop r9
    pop r8
.skip_dbg:

    inc dword [sub_ticks]
    cmp dword [sub_ticks], PIT_FREQUENCY
    jl .done

    mov dword [sub_ticks], 0
    inc dword [time_seconds]
    cmp dword [time_seconds], 60
    jl .done

    mov dword [time_seconds], 0
    inc dword [time_minutes]
    cmp dword [time_minutes], 60
    jl .done

    mov dword [time_minutes], 0
    inc dword [time_hours]
    cmp dword [time_hours], 24
    jl .done
    mov dword [time_hours], 0

.done:
    pop rcx
    pop rdi
    pop rdx
    pop rax
    ret

; --- src/kernel/pit.asm (BOTTOM SECTION) ---
section .data
align 16
global tick_count, last_fps, frame_count, start_tick, time_hours, time_minutes

tick_count:     dq 0
sub_ticks:      dd 0
time_seconds:   dd 0
time_minutes:   dd 0
time_hours:     dd 12
fps_count:      dd 0
last_fps:       dd 0
frame_count:    dd 0
start_tick:     dq 0
