; ============================================================================
; NexusOS v3.0 - PIT (8253/8254) Timer Driver
; 100Hz tick rate, provides system uptime and clock
; ============================================================================
bits 64

%include "constants.inc"

section .text

; --- Initialize PIT Channel 0 at 100Hz ---
extern frame_count
extern start_tick
global pit_init
pit_init:
    ; Channel 0, lobyte/hibyte, rate generator (mode 2)
    mov al, 0x36             ; 00 11 010 0 = Ch0, lobyte/hibyte, rate gen, binary
    out 0x43, al

    ; Set divisor = 11932 (0x2E9C) -> ~100Hz
    mov ax, PIT_DIVISOR
    out 0x40, al             ; Low byte
    mov al, ah
    out 0x40, al             ; High byte

    ; Initialize time fields
    mov qword [tick_count], 0
    mov dword [frame_count], 0
    mov dword [start_tick], 0
    mov dword [time_seconds], 0
    mov dword [time_minutes], 0
    mov dword [time_hours], 0
    mov dword [sub_ticks], 0

    ret

; --- PIT IRQ0 Handler (called from ISR) ---
; Called at 100Hz. Increments tick counter and updates time.
global pit_handler
pit_handler:
    push rax
    push rdx

    ; Increment tick counter
    inc qword [tick_count]

    ; Increment sub-tick counter for seconds
    inc dword [sub_ticks]
    cmp dword [sub_ticks], PIT_FREQUENCY  ; 100 ticks = 1 second
    jl .done

    ; One second elapsed
    mov dword [sub_ticks], 0
    inc dword [time_seconds]
    cmp dword [time_seconds], 60
    jl .done

    ; One minute elapsed
    mov dword [time_seconds], 0
    inc dword [time_minutes]
    cmp dword [time_minutes], 60
    jl .done

    ; One hour elapsed
    mov dword [time_minutes], 0
    inc dword [time_hours]
    cmp dword [time_hours], 24
    jl .done
    mov dword [time_hours], 0

.done:
    pop rdx
    pop rax
    ret

; --- Get tick count ---
; Returns: RAX = tick count
global pit_get_ticks
pit_get_ticks:
    mov rax, [tick_count]
    ret

; --- Simple delay (blocking) ---
; RDI = number of ticks to wait (each tick = 10ms)
global pit_delay
pit_delay:
    mov rax, [tick_count]
    add rdi, rax             ; Target tick
.wait:
    hlt                      ; Wait for interrupt
    cmp [tick_count], rdi
    jl .wait
    ret

section .data
global tick_count
global time_seconds, time_minutes, time_hours

tick_count:     dq 0
sub_ticks:      dd 0
time_seconds:   dd 0
time_minutes:   dd 0
time_hours:     dd 0
