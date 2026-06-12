bits 64

%include "constants.inc"

MAX_DIRTY_RECTS equ 32

section .text
db "RENDER_START"

; Import from display driver
extern display_flip_rect
extern display_flip
extern fill_rect
extern draw_string
extern draw_hline
extern draw_vline
extern display_clear
extern bb_addr
extern scr_width
extern scr_height
extern scr_pitch_q

; SMP work queue (proc/workqueue.asm) - the flip blit runs on an AP
extern workqueue_submit
extern workqueue_wait_timeout

; Export to GUI
global render_init
global render_rect
global render_text
global render_line
global render_get_backbuffer
global render_mark_dirty
global render_mark_full
global render_flush
global render_restore_dirty_backbuffer
global render_save_dirty_backbuffer

; --- Initialize render system ---
render_init:
    mov dword [dirty_count], 0
    mov byte [full_redraw], 1    ; First frame: full redraw
    ret

; --- Wrappers ---
render_rect:
    jmp fill_rect

render_text:
    jmp draw_string

render_line:
    ret

render_get_backbuffer:
    mov rax, [bb_addr]
    ret

; --- Mark a rectangle as dirty ---
; EDI = x, ESI = y, EDX = w, ECX = h
render_mark_dirty:
    push rax

    ; If too many dirty rects, just do full redraw
    mov eax, [dirty_count]
    cmp eax, MAX_DIRTY_RECTS
    jge .mark_full

    ; Store dirty rect
    shl eax, 4              ; * 16 bytes per rect
    lea rax, [dirty_rects + rax]
    mov [rax], edi           ; x
    mov [rax + 4], esi       ; y
    mov [rax + 8], edx       ; w
    mov [rax + 12], ecx      ; h
    inc dword [dirty_count]
    pop rax
    ret

.mark_full:
    mov byte [full_redraw], 1
    pop rax
    ret

; --- Mark entire screen as dirty ---
render_mark_full:
    mov byte [full_redraw], 1
    ret

; --- Flush dirty rectangles to framebuffer (async: blit runs on an AP) ---
; The BSP snapshots the dirty list into the flip_* shadows, submits
; render_flip_job to the work queue, and returns to interactive work while an
; AP does the backbuffer->FB copy. At most one job is in flight: the previous
; frame's job is drained before the shadows are rewritten, so an AP never
; reads them mid-update. The AP blits from the live backbuffer, so a frame
; rendered concurrently can tear within a rect; the next flush repaints it.
; Single-core builds degrade cleanly - workqueue_submit runs the job inline.
render_flush:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi

    ; Drain the previous flip job (normally DONE already => near-zero wait).
    ; Timeout-guarded like dispatch_app_callback: if the owning AP wedged, we
    ; leak the slot and carry on rather than freezing the GUI.
    mov edi, [flip_job_handle]
    cmp edi, -1
    je .no_pending
    mov esi, 50                  ; PIT-tick budget (never raw-counter; STATUS.md)
    call workqueue_wait_timeout
    mov dword [flip_job_handle], -1
.no_pending:

    ; Anything to do this frame?
    cmp byte [full_redraw], 0
    jne .snapshot
    cmp dword [dirty_count], 0
    je .flush_done

.snapshot:
    ; Snapshot dirty state into the job-owned shadows, then reset the live
    ; list so the BSP can mark new rects while the AP blits these.
    mov al, [full_redraw]
    mov [flip_full], al
    mov ecx, [dirty_count]
    mov [flip_count], ecx
    shl ecx, 2                   ; rect count -> dword count (16 bytes/rect)
    lea rsi, [dirty_rects]
    lea rdi, [flip_rects]
    rep movsd
    mov dword [dirty_count], 0
    mov byte [full_redraw], 0

    ; Hand the blit to an AP. High priority so app jobs cannot starve frames.
    mov rdi, render_flip_job
    xor esi, esi
    mov edx, 2                   ; WQ_PRIO_HIGH
    call workqueue_submit
    cmp eax, -1                  ; WQ_INVALID: queue full -> blit on the BSP
    jne .submitted
    xor edi, edi
    call render_flip_job
    jmp .flush_done
.submitted:
    mov [flip_job_handle], eax

.flush_done:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; --- render_flip_job(RDI = unused) -> RAX = 0. Runs on an AP (or inline). ---
; Blits the snapshotted rects (or the whole screen) backbuffer -> FB. Reads
; only the flip_* shadows the BSP wrote before publishing the job; x86 store
; ordering makes them visible together with the PENDING status word. Preserves
; RBX/RBP/R12-R15 per the workqueue job contract.
render_flip_job:
    push rbx
    cmp byte [flip_full], 0
    jne .full
    mov ebx, [flip_count]
    test ebx, ebx
    jz .done
    xor eax, eax            ; Index
.rect_loop:
    cmp eax, ebx
    jge .done
    push rax
    shl eax, 4
    lea r8, [flip_rects + rax]
    mov edi, [r8]
    mov esi, [r8 + 4]
    mov edx, [r8 + 8]
    mov ecx, [r8 + 12]
    call display_flip_rect
    pop rax
    inc eax
    jmp .rect_loop
.full:
    call display_flip
    mov byte [flip_full], 0
.done:
    pop rbx
    xor eax, eax
    ret

; --- Save back buffer (RAM -> RAM) SSE2 optimized, 128 bytes/iteration ---
global render_save_backbuffer
render_save_backbuffer:
    push rdi
    push rsi
    push rcx
    push rdx
    push rax

    mov rdi, BACK_BUFFER_SAVE_ADDR
    mov rsi, [bb_addr]
    mov rax, [scr_pitch_q]
    mov edx, [scr_height]
    imul rax, rdx              ; active framebuffer bytes
    mov rdx, rax

    ; SSE2 copy: 128 bytes per iteration (8x movdqa load, 8x movdqa store)
    mov rcx, rdx
    shr rcx, 7                ; / 128
    jz .save_tail
.save_loop:
    movdqa xmm0, [rsi]
    movdqa xmm1, [rsi + 16]
    movdqa xmm2, [rsi + 32]
    movdqa xmm3, [rsi + 48]
    movdqa xmm4, [rsi + 64]
    movdqa xmm5, [rsi + 80]
    movdqa xmm6, [rsi + 96]
    movdqa xmm7, [rsi + 112]
    movdqa [rdi], xmm0
    movdqa [rdi + 16], xmm1
    movdqa [rdi + 32], xmm2
    movdqa [rdi + 48], xmm3
    movdqa [rdi + 64], xmm4
    movdqa [rdi + 80], xmm5
    movdqa [rdi + 96], xmm6
    movdqa [rdi + 112], xmm7
    add rsi, 128
    add rdi, 128
    dec ecx
    jnz .save_loop

    ; Handle remainder (active bytes % 128)
.save_tail:
    mov rcx, rdx
    and rcx, 127
    rep movsb

    pop rax
    pop rdx
    pop rcx
    pop rsi
    pop rdi
    ret

; --- Restore back buffer (RAM -> RAM) SSE2 optimized, 128 bytes/iteration ---
global render_restore_backbuffer
render_restore_backbuffer:
    push rdi
    push rsi
    push rcx
    push rdx
    push rax

    mov rdi, [bb_addr]
    mov rsi, BACK_BUFFER_SAVE_ADDR
    mov rax, [scr_pitch_q]
    mov edx, [scr_height]
    imul rax, rdx              ; active framebuffer bytes
    mov rdx, rax

    ; SSE2 copy: 128 bytes per iteration
    mov rcx, rdx
    shr rcx, 7                ; / 128
    jz .restore_tail
.restore_loop:
    movdqa xmm0, [rsi]
    movdqa xmm1, [rsi + 16]
    movdqa xmm2, [rsi + 32]
    movdqa xmm3, [rsi + 48]
    movdqa xmm4, [rsi + 64]
    movdqa xmm5, [rsi + 80]
    movdqa xmm6, [rsi + 96]
    movdqa xmm7, [rsi + 112]
    movdqa [rdi], xmm0
    movdqa [rdi + 16], xmm1
    movdqa [rdi + 32], xmm2
    movdqa [rdi + 48], xmm3
    movdqa [rdi + 64], xmm4
    movdqa [rdi + 80], xmm5
    movdqa [rdi + 96], xmm6
    movdqa [rdi + 112], xmm7
    add rsi, 128
    add rdi, 128
    dec ecx
    jnz .restore_loop

    ; Remainder
.restore_tail:
    mov rcx, rdx
    and rcx, 127
    rep movsb

    pop rax
    pop rdx
    pop rcx
    pop rsi
    pop rdi
    ret

; --- Restore only current dirty rectangles from saved backbuffer ---
; Used during titlebar drag so each mouse move copies/flips just the old and
; new outline areas instead of the whole framebuffer.
render_restore_dirty_backbuffer:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13

    mov r13d, [dirty_count]
    test r13d, r13d
    jz .rdb_done

    xor r12d, r12d
.rdb_loop:
    cmp r12d, r13d
    jge .rdb_done

    mov eax, r12d
    shl eax, 4
    lea rbx, [dirty_rects + rax]
    mov edi, [rbx]          ; x
    mov esi, [rbx + 4]      ; y
    mov edx, [rbx + 8]      ; w
    mov ecx, [rbx + 12]     ; h

    ; Clip left/top.
    test edi, edi
    jge .clip_left_ok
    add edx, edi
    xor edi, edi
.clip_left_ok:
    test esi, esi
    jge .clip_top_ok
    add ecx, esi
    xor esi, esi
.clip_top_ok:
    test edx, edx
    jle .rdb_next
    test ecx, ecx
    jle .rdb_next

    ; Clip right/bottom.
    mov eax, [scr_width]
    sub eax, edi
    cmp edx, eax
    jle .clip_right_ok
    mov edx, eax
.clip_right_ok:
    mov eax, [scr_height]
    sub eax, esi
    cmp ecx, eax
    jle .clip_bottom_ok
    mov ecx, eax
.clip_bottom_ok:
    test edx, edx
    jle .rdb_next
    test ecx, ecx
    jle .rdb_next

    ; r8/r9 = dst/src row starts, r10 = pitch, r11d = width in dwords.
    mov r10, [scr_pitch_q]
    mov eax, esi
    imul rax, r10
    mov r8, [bb_addr]
    add r8, rax
    mov r9, BACK_BUFFER_SAVE_ADDR
    add r9, rax
    mov eax, edi
    shl eax, 2
    add r8, rax
    add r9, rax
    mov r11d, edx

.rdb_row:
    test ecx, ecx
    jz .rdb_next
    push rcx
    mov rdi, r8
    mov rsi, r9
    mov ecx, r11d
    rep movsd
    pop rcx
    add r8, r10
    add r9, r10
    dec ecx
    jmp .rdb_row

.rdb_next:
    inc r12d
    jmp .rdb_loop

.rdb_done:
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; --- Save only current dirty rectangles into the saved backbuffer ------------
; Used by partial live-window refresh paths so later cursor/drag restores see
; the newest pixels without copying the entire screen.
render_save_dirty_backbuffer:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13

    mov r13d, [dirty_count]
    test r13d, r13d
    jz .sdb_done

    xor r12d, r12d
.sdb_loop:
    cmp r12d, r13d
    jge .sdb_done

    mov eax, r12d
    shl eax, 4
    lea rbx, [dirty_rects + rax]
    mov edi, [rbx]
    mov esi, [rbx + 4]
    mov edx, [rbx + 8]
    mov ecx, [rbx + 12]

    test edi, edi
    jge .clip_left_ok
    add edx, edi
    xor edi, edi
.clip_left_ok:
    test esi, esi
    jge .clip_top_ok
    add ecx, esi
    xor esi, esi
.clip_top_ok:
    test edx, edx
    jle .sdb_next
    test ecx, ecx
    jle .sdb_next

    mov eax, [scr_width]
    sub eax, edi
    cmp edx, eax
    jle .clip_right_ok
    mov edx, eax
.clip_right_ok:
    mov eax, [scr_height]
    sub eax, esi
    cmp ecx, eax
    jle .clip_bottom_ok
    mov ecx, eax
.clip_bottom_ok:
    test edx, edx
    jle .sdb_next
    test ecx, ecx
    jle .sdb_next

    mov r10, [scr_pitch_q]
    mov eax, esi
    imul rax, r10
    mov r8, BACK_BUFFER_SAVE_ADDR
    add r8, rax
    mov r9, [bb_addr]
    add r9, rax
    mov eax, edi
    shl eax, 2
    add r8, rax
    add r9, rax
    mov r11d, edx

.sdb_row:
    test ecx, ecx
    jz .sdb_next
    push rcx
    mov rdi, r8
    mov rsi, r9
    mov ecx, r11d
    rep movsd
    pop rcx
    add r8, r10
    add r9, r10
    dec ecx
    jmp .sdb_row

.sdb_next:
    inc r12d
    jmp .sdb_loop

.sdb_done:
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

section .data

dirty_count    dd 0
full_redraw    db 0
dirty_rects    times MAX_DIRTY_RECTS * 16 db 0

; Async-flip shadow state: written by the BSP in render_flush (only while no
; job is in flight), read by the AP running render_flip_job.
flip_job_handle dd -1
flip_count      dd 0
flip_full       db 0
align 16
flip_rects      times MAX_DIRTY_RECTS * 16 db 0

section .bss

section .text
