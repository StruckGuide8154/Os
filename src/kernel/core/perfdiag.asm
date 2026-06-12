; ============================================================================
; Grit v3.0 - Cache32Max CPU/cache/frequency diagnostics
; ============================================================================
bits 64

%include "constants.inc"
%include "macros.inc"

extern ser_print_hex64
extern tick_count
extern madt_enabled_cpu_count
extern smp_target_cores
extern smp_started_cores
extern smp_alive_cores
extern smp_parked_cores
extern l3_app_arena_base_v
extern pci_gpu_scan
extern pci_gpu_count
extern pci_gpu_radeon780m_found
extern pci_gpu_radeon780m_bdf
extern pci_gpu_radeon780m_id
extern pci_gpu_radeon780m_class
extern pci_gpu_radeon780m_bar0
extern pci_gpu_radeon780m_cmd
extern pci_gpu_amd_display_found
extern pci_gpu_amd_display_bdf
extern pci_gpu_amd_display_id
extern pci_gpu_amd_display_class
extern pci_gpu_amd_display_bar0
extern pci_gpu_amd_display_cmd
extern amd_display_active
extern amd_display_status
extern amd_display_bdf
extern amd_display_mode_w
extern amd_display_mode_h
extern amd_display_mode_pitch

section .text
global perfdiag_init
global perfdiag_print_profile
global perfdiag_print_memory
global perfdiag_print_smp
global perfdiag_print_pci_gpu
global perfdiag_benchmark

perfdiag_init:
    call perfdiag_collect
    call perfdiag_print_profile
    ret

perfdiag_collect:
    push rax
    push rbx
    push rcx
    push rdx

    mov eax, 0x80000000
    cpuid
    cmp eax, 0x80000006
    jb .fallback

    mov eax, 0x80000005
    cpuid
    mov eax, ecx
    shr eax, 24
    mov [l1d_kb], eax
    mov eax, edx
    shr eax, 24
    mov [l1i_kb], eax

    mov eax, 0x80000006
    cpuid
    mov eax, ecx
    shr eax, 16
    mov [l2_kb], eax
    mov eax, edx
    shr eax, 18
    and eax, 0x3FFF
    shl eax, 9
    mov [l3_kb], eax
    jmp .topology

.fallback:
    mov dword [l1d_kb], 32
    mov dword [l1i_kb], 32
    mov dword [l2_kb], 1024
    mov dword [l3_kb], 16384

.topology:
    mov eax, 1
    cpuid
    mov eax, ebx
    shr eax, 16
    and eax, 0xFF
    test eax, eax
    jnz .store_logical
    mov eax, 1
.store_logical:
    mov [cpuid_logical_count], eax

    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

perfdiag_print_profile:
    push rdi
    lea rdi, [rel msg_cpu]
    call serial_puts
    mov eax, [cpuid_logical_count]
    mov rdi, rax
    call ser_print_hex64
    call serial_crlf

    lea rdi, [rel msg_cache]
    call serial_puts
    mov eax, [l1d_kb]
    add eax, [l1i_kb]
    mov rdi, rax
    call ser_print_hex64
    SER '/'
    mov eax, [l2_kb]
    mov rdi, rax
    call ser_print_hex64
    SER '/'
    mov eax, [l3_kb]
    mov rdi, rax
    call ser_print_hex64
    call serial_crlf

    lea rdi, [rel msg_freq]
    call serial_puts
    call measure_tsc_tick
    mov [cpu_tsc_per_tick], rax
    mov rdi, rax
    call ser_print_hex64
    call serial_crlf

    call perfdiag_print_memory
    call perfdiag_print_smp
    pop rdi
    ret

perfdiag_print_memory:
    push rdi
    lea rdi, [rel msg_memcap]
    call serial_puts
%ifdef GRIT_CACHE32_MAX
    mov rdi, CACHE32_RAM_LIMIT
%else
    xor rdi, rdi
%endif
    call ser_print_hex64
    SER ' '
    lea rdi, [rel msg_gui]
    call serial_puts
    mov rdi, GUI_LLC_ARENA_START
    call ser_print_hex64
    SER '-'
    mov rdi, GUI_LLC_ARENA_END
    call ser_print_hex64
    SER ' '
    lea rdi, [rel msg_app]
    call serial_puts
    mov rdi, [rel l3_app_arena_base_v]
    call ser_print_hex64
    call serial_crlf
    pop rdi
    ret

perfdiag_print_smp:
    push rdi
    lea rdi, [rel msg_smp]
    call serial_puts
    mov eax, [madt_enabled_cpu_count]
    test eax, eax
    jnz .have_madt
%ifdef GRIT_CACHE32_MAX
    mov eax, [cpuid_logical_count]
    cmp eax, 2
    jb .have_madt
    mov eax, 1
    jmp .have_madt
%endif
    mov eax, [cpuid_logical_count]
.have_madt:
    mov rdi, rax
    call ser_print_hex64
    SER '/'
    mov eax, [smp_target_cores]
    mov rdi, rax
    call ser_print_hex64
    SER '/'
    mov eax, [smp_started_cores]
    mov rdi, rax
    call ser_print_hex64
    SER '/'
    mov eax, [smp_alive_cores]
    mov rdi, rax
    call ser_print_hex64
    SER '/'
    mov eax, [smp_parked_cores]
    mov rdi, rax
    call ser_print_hex64
    call serial_crlf
    pop rdi
    ret

perfdiag_print_pci_gpu:
    push rdi
    call pci_gpu_scan
    lea rdi, [rel msg_gpu780m]
    call serial_puts
    movzx eax, byte [pci_gpu_radeon780m_found]
    mov rdi, rax
    call ser_print_hex64
    SER ' '
    lea rdi, [rel msg_gpu_count]
    call serial_puts
    movzx eax, byte [pci_gpu_count]
    mov rdi, rax
    call ser_print_hex64
    cmp byte [pci_gpu_radeon780m_found], 0
    je .done
    SER ' '
    lea rdi, [rel msg_gpu_bdf]
    call serial_puts
    mov eax, [pci_gpu_radeon780m_bdf]
    mov rdi, rax
    call ser_print_hex64
    SER ' '
    lea rdi, [rel msg_gpu_id]
    call serial_puts
    mov eax, [pci_gpu_radeon780m_id]
    mov rdi, rax
    call ser_print_hex64
    SER ' '
    lea rdi, [rel msg_gpu_class]
    call serial_puts
    mov eax, [pci_gpu_radeon780m_class]
    mov rdi, rax
    call ser_print_hex64
    SER ' '
    lea rdi, [rel msg_gpu_bar0]
    call serial_puts
    mov rdi, [pci_gpu_radeon780m_bar0]
    call ser_print_hex64
    SER ' '
    lea rdi, [rel msg_gpu_cmd]
    call serial_puts
    mov eax, [pci_gpu_radeon780m_cmd]
    mov rdi, rax
    call ser_print_hex64
.done:
    call serial_crlf
    cmp byte [pci_gpu_radeon780m_found], 0
    jne .ret
    cmp byte [pci_gpu_amd_display_found], 0
    je .ret
    lea rdi, [rel msg_gpu_amd]
    call serial_puts
    SER ' '
    lea rdi, [rel msg_gpu_bdf]
    call serial_puts
    mov eax, [pci_gpu_amd_display_bdf]
    mov rdi, rax
    call ser_print_hex64
    SER ' '
    lea rdi, [rel msg_gpu_id]
    call serial_puts
    mov eax, [pci_gpu_amd_display_id]
    mov rdi, rax
    call ser_print_hex64
    SER ' '
    lea rdi, [rel msg_gpu_class]
    call serial_puts
    mov eax, [pci_gpu_amd_display_class]
    mov rdi, rax
    call ser_print_hex64
    SER ' '
    lea rdi, [rel msg_gpu_bar0]
    call serial_puts
    mov rdi, [pci_gpu_amd_display_bar0]
    call ser_print_hex64
    SER ' '
    lea rdi, [rel msg_gpu_cmd]
    call serial_puts
    mov eax, [pci_gpu_amd_display_cmd]
    mov rdi, rax
    call ser_print_hex64
    call serial_crlf
.ret:
    lea rdi, [rel msg_amddisp]
    call serial_puts
    movzx eax, byte [amd_display_active]
    mov rdi, rax
    call ser_print_hex64
    SER ' '
    lea rdi, [rel msg_gpu_status]
    call serial_puts
    mov eax, [amd_display_status]
    mov rdi, rax
    call ser_print_hex64
    SER ' '
    lea rdi, [rel msg_gpu_bdf]
    call serial_puts
    mov eax, [amd_display_bdf]
    mov rdi, rax
    call ser_print_hex64
    SER ' '
    lea rdi, [rel msg_gpu_mode]
    call serial_puts
    mov eax, [amd_display_mode_w]
    mov rdi, rax
    call ser_print_hex64
    SER 'x'
    mov eax, [amd_display_mode_h]
    mov rdi, rax
    call ser_print_hex64
    SER ' '
    lea rdi, [rel msg_gpu_pitch]
    call serial_puts
    mov eax, [amd_display_mode_pitch]
    mov rdi, rax
    call ser_print_hex64
    call serial_crlf
    pop rdi
    ret

perfdiag_benchmark:
    push rbx
    push rcx
    push rdx
    push rdi
    lea rdi, [rel msg_bench]
    call serial_puts
    call rdtsc64
    mov rbx, rax
    mov ecx, 2000000
.loop:
    imul rax, rax, 1103515245
    add rax, 12345
    dec ecx
    jnz .loop
    mov rdx, rax
    call rdtsc64
    sub rax, rbx
    mov rdi, rax
    call ser_print_hex64
    SER ':'
    mov rdi, rdx
    call ser_print_hex64
    call serial_crlf
    pop rdi
    pop rdx
    pop rcx
    pop rbx
    ret

measure_tsc_tick:
    ; Wait for a PIT tick edge, snapshot TSC, wait for the next edge, snapshot
    ; again. The delta is cycles per PIT tick (10 ms by pit_init).
    ;
    ; Old design used a fixed iteration count (5M) as the "PIT didn't fire"
    ; bailout, but on fast real hardware (e.g. Zen 5 at ~5 GHz) that loop
    ; completes in ~3 ms - less than one PIT tick - so we'd time out before
    ; ever seeing a tick edge and return 0. cpu_tsc_per_tick then stayed 0
    ; and every per-core MHz computation produced 0. Use a TSC-based real-
    ; time deadline (~250 ms) so the bailout is independent of CPU speed.
    push rbx
    push rcx
    push rdx
    push r8
    push r9

    pushfq
    pop rax
    test eax, 0x200
    jz .no_if

    ; Build a TSC-based real-time deadline. We don't know the TSC rate yet,
    ; but +500M cycles is 500 ms at 1 GHz and ~100 ms at 5 GHz - both far
    ; longer than the 10 ms PIT tick. If a tick hasn't fired by then, the
    ; PIT is broken and bailing is correct.
    call rdtsc64
    mov r9, rax
    add r9, 500000000

    mov rbx, [tick_count]
.wait_first:
    cmp [tick_count], rbx
    jne .got_first
    call rdtsc64
    cmp rax, r9
    jae .no_if
    pause
    jmp .wait_first
.got_first:
    call rdtsc64
    mov r8, rax

    ; Same deadline strategy for the second edge.
    call rdtsc64
    mov r9, rax
    add r9, 500000000
    mov rbx, [tick_count]
.wait_second:
    cmp [tick_count], rbx
    jne .got_second
    call rdtsc64
    cmp rax, r9
    jae .no_if
    pause
    jmp .wait_second
.got_second:
    call rdtsc64
    sub rax, r8
    jmp .done

.no_if:
    xor eax, eax
.done:
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rbx
    ret

rdtsc64:
    push rdx
    rdtsc
    shl rdx, 32
    or rax, rdx
    pop rdx
    ret

serial_puts:
    push rax
    push rdx
    push rdi
.loop:
    mov al, [rdi]
    test al, al
    jz .done
    call serial_putc
    inc rdi
    jmp .loop
.done:
    pop rdi
    pop rdx
    pop rax
    ret

serial_crlf:
    push rax
    mov al, 13
    call serial_putc
    mov al, 10
    call serial_putc
    pop rax
    ret

serial_putc:
    push rdx
    push rax
    mov dx, 0x3F8 + 5
.wait:
    in al, dx
    test al, 0x20
    jz .wait
    pop rax
    mov dx, 0x3F8
    out dx, al
    pop rdx
    ret

section .data
align 64
l1d_kb: dd 32
l1i_kb: dd 32
l2_kb: dd 1024
l3_kb: dd 16384
global cpuid_logical_count
cpuid_logical_count: dd 1
; TSC ticks elapsed over one PIT tick (10ms). CPU Hz = value * 100, so
; MHz = value / 10000. Captured once by perfdiag_print_profile.
global cpu_tsc_per_tick
cpu_tsc_per_tick: dq 0

msg_cpu:    db 'CPU:', 0
msg_cache:  db 'CACHE:', 0
msg_freq:   db 'FREQ:', 0
msg_memcap: db 'MEMCAP:', 0
msg_gui:    db 'GUI:', 0
msg_app:    db 'APP:', 0
msg_smp:    db 'SMP:', 0
msg_gpu780m: db 'GPU780M:', 0
msg_gpu_count: db 'DISP:', 0
msg_gpu_bdf: db 'BDF:', 0
msg_gpu_id: db 'ID:', 0
msg_gpu_class: db 'CLASS:', 0
msg_gpu_bar0: db 'BAR0:', 0
msg_gpu_cmd: db 'CMD:', 0
msg_gpu_amd: db 'GPUAMD:', 0
msg_amddisp: db 'AMDDISP:', 0
msg_gpu_status: db 'STATUS:', 0
msg_gpu_mode: db 'MODE:', 0
msg_gpu_pitch: db 'PITCH:', 0
msg_bench:  db 'BENCH:', 0
