; ============================================================================
; NexusOS Diagnostic - UEFI Mouse Probe (BOOTX64.EFI)
; ----------------------------------------------------------------------------
; Goal: find a UEFI pointer protocol path that actually delivers mouse and
; touchpad movement on the Acer Nitro V16 AI (AMD Ryzen AI 9 HX / Strix Point /
; Radeon 890M). The current NexusOS kernel cannot drive xHCI input on that
; hardware. UEFI firmware drivers DO work (mouse + touchpad work in BIOS), so
; this probe stays inside UEFI Boot Services forever and tries every protocol
; UEFI exposes for pointer input.
;
; Methods attempted:
;   1. EFI_SIMPLE_POINTER_PROTOCOL  via LocateProtocol
;   2. EFI_SIMPLE_POINTER_PROTOCOL  via LocateHandleBuffer -> OpenProtocol
;      (some firmwares only attach SPP to specific device handles)
;   3. EFI_ABSOLUTE_POINTER_PROTOCOL via LocateProtocol  (touchscreen / touchpad)
;   4. EFI_ABSOLUTE_POINTER_PROTOCOL via LocateHandleBuffer enumeration
;
; Display: GOP framebuffer cleared to black. A square at the cursor position
; moves whenever any pointer source reports motion. A row of coloured dots
; along the top indicates which probe paths succeeded:
;     red   = SPP via LocateProtocol         (slot 0)
;     orange= SPP via handle enumeration     (slot 1)
;     green = Absolute Pointer LocateProtocol(slot 2)
;     cyan  = Absolute Pointer handle enum   (slot 3)
;   dim grey if not found, bright if found, blink if GetState returns "ready".
;
; Serial trace on COM1 (0x3F8) for each step for headless diagnosis.
; ============================================================================
bits 64
default rel

%define HDR_SZ       0x200
%define TEXT_RAW     0x10000
%define TEXT_VA      0x1000
%define RELOC_FOFF   (HDR_SZ + TEXT_RAW)
%define RELOC_FSZ    0x200
%define RELOC_VA     0x11000
%define RELOC_VSZ    0x0C
%define IMAGE_SZ     0x12000
%define IMAGE_BASE   0x400000

; UEFI table offsets
%define ST_CONOUT    64
%define ST_BOOTSVC   96
%define BS_LOCHNDL   312
%define BS_LOCATE    320
%define BS_HNDLPROT  152
%define BS_OPENPROT  280
%define BS_WATCHDOG  256
%define BS_STALL     248
%define BS_CHECKEVT  120
%define BS_CONNECT   264
%define BS_DISCONN   272
%define BS_CLOSEPROT 288

; GOP
%define GOP_QUERY    0
%define GOP_SET      8
%define GOP_MODE     24
%define GOPM_MAX     0
%define GOPM_CUR     4
%define GOPM_FBBASE  24
%define GOPI_HRES    4
%define GOPI_VRES    8
%define GOPI_PPSL    32

; Simple Pointer Protocol vtable offsets
%define SPP_RESET    0
%define SPP_GETSTATE 8
%define SPP_WAITKEY  16
%define SPP_MODE     24

; Absolute Pointer Protocol vtable offsets
%define APP_RESET    0
%define APP_GETSTATE 8
%define APP_WAITKEY  16
%define APP_MODE     24

; ConOut (EFI_SIMPLE_TEXT_OUTPUT_PROTOCOL)
%define CO_RESET     0
%define CO_OUTPUT    8
%define CO_SETATTR   40
%define CO_CLEAR     48
%define CO_SETCURPOS 56
%define CO_ENABLECUR 64

; ============================================================================
; NAMED CONSTANTS (replacing bare 5+ hex-digit "magic" literals)
; Values copied verbatim from their original literals. Do not alter a digit.
; ----------------------------------------------------------------------------
; PE/COFF header fields
PE_SIGNATURE          equ 0x00004550   ; "PE\0\0" optional-header signature
SECCHAR_TEXT          equ 0xE0000060   ; .text  flags: CODE|EXEC|READ (+MEM_…)
SECCHAR_RELOC         equ 0x42000040   ; .reloc flags: INITDATA|DISCARDABLE|READ

; --- BGRA pixel colors (0x00RRGGBB / GOP BltPixel layout) ---
COLOR_TEST_RECT_GREEN equ 0x0000FF00   ; T07 test-rect green (line 320)
COLOR_BG_DARK_SLATE   equ 0x00000810   ; very dark blue-grey screen clear
COLOR_CURSOR_MAGENTA  equ 0x00FF00FF   ; bright magenta cursor / async bar
COLOR_BG_UEFI_BLUE    equ 0x000000A8   ; UEFI EFI_BACKGROUND_BLUE (BGRA) erase
COLOR_DARK_RED        equ 0x00800000   ; slot0 idle (dark red)
COLOR_BRIGHT_RED      equ 0x00FF0000   ; slot0 active (bright red)
COLOR_DIM_GREY        equ 0x00303030   ; status slot "not found" dim grey
COLOR_DARK_ORANGE     equ 0x00803000   ; slot1 idle (dark orange)
COLOR_BRIGHT_ORANGE   equ 0x00FF8000   ; slot1 active (bright orange)
COLOR_DARK_GREEN      equ 0x00006000   ; slot2 idle (dark green)
COLOR_BRIGHT_GREEN    equ 0x0000FF00   ; slot2 active (bright green)
COLOR_DARK_CYAN       equ 0x00006080   ; slot3 idle (dark cyan)
COLOR_BRIGHT_CYAN     equ 0x0000FFFF   ; slot3 active / cb indicator (bright cyan)
COLOR_DARK_YELLOW     equ 0x00606000   ; slot4 idle (dark yellow)
COLOR_YELLOW          equ 0x00FFFF00   ; slot4 active / HITS bar (yellow)
COLOR_PANEL_BG        equ 0x00080808   ; usb panel clear strip (near-black)
COLOR_RC_GREEN        equ 0x0000C000   ; RC square pass (green)
COLOR_RC_RED          equ 0x00C00000   ; RC square fail (red)
COLOR_WHITE           equ 0x00FFFFFF   ; byte-bar b0 / report white
COLOR_BAR_RED         equ 0x00FF4040   ; byte-bar b1 (red)
COLOR_BAR_GREEN       equ 0x0040FF40   ; byte-bar b2 (green)
COLOR_BAR_CYAN        equ 0x0040FFFF   ; byte-bar b3 (cyan)
COLOR_CB_DARK_GREY    equ 0x00202020   ; async cb indicator dark grey (never fired)
COLOR_BLACK           equ 0x00000000   ; dead-code report-bar background (black)

; --- EFI GUID data1 (first 32-bit field of each protocol GUID) ---
EFI_GOP_GUID_D1       equ 0x9042a9de   ; EFI_GRAPHICS_OUTPUT_PROTOCOL_GUID data1
EFI_SPP_GUID_D1       equ 0x31878c87   ; EFI_SIMPLE_POINTER_PROTOCOL_GUID data1
EFI_APP_GUID_D1       equ 0x8d59d32b   ; EFI_ABSOLUTE_POINTER_PROTOCOL_GUID data1
EFI_USBIO_GUID_D1     equ 0x2b2f68d6   ; EFI_USB_IO_PROTOCOL_GUID data1
; ============================================================================

; --- Serial helpers ---
%macro SER 1
    push rax
    push rdx
    mov dx, 0x3F8
    mov al, %1
    out dx, al
    pop rdx
    pop rax
%endmacro

%macro SDBG 1
    push rax
    push rdx
    mov dx, 0x3F8
    %strlen %%n %1
    %assign %%i 1
    %rep %%n
      %substr %%c %1 %%i
      mov al, %%c
      out dx, al
      %assign %%i %%i+1
    %endrep
    mov al, 13
    out dx, al
    mov al, 10
    out dx, al
    pop rdx
    pop rax
%endmacro

; --- UCS-2 string macro ---
%macro ustr 1+
  %assign %%i 1
  %strlen %%n %1
  %rep %%n
    %substr %%c %1 %%i
    dw %%c
    %assign %%i %%i+1
  %endrep
  dw 0
%endmacro

; --- On-screen step tracer.  Emits an inline UCS-2 string, jumps over it,
; prints it via ConOut and stalls so each step is readable one-at-a-time. ---
%macro TRACE 1
    push rsi
    jmp %%skip
  %%tstr:
    ustr %1
  %%skip:
    lea rsi, [%%tstr]
    call trace_step
    pop rsi
%endmacro

; --- TRACE only during the first few frames (v_frame < 3) ---
%macro TRACEF 1
    cmp dword [v_frame], 3
    jae %%done
    TRACE %1
  %%done:
%endmacro

; ============================================================================
; PE/COFF HEADER
; ============================================================================
section .text start=0
    dw 0x5A4D
    times 29 dw 0
    dd pe_hdr

pe_hdr:
    dd PE_SIGNATURE
    dw 0x8664
    dw 2
    dd 0, 0, 0
    dw opt_end - opt_hdr
    dw 0x0206

opt_hdr:
    dw 0x020B
    db 1, 0
    dd TEXT_RAW, 0, 0, TEXT_VA, TEXT_VA
    dq IMAGE_BASE
    dd 0x1000, 0x200
    dw 0,0, 0,0, 0,0
    dd 0, IMAGE_SZ, HDR_SZ, 0
    dw 10, 0
    dq IMAGE_BASE, IMAGE_BASE, IMAGE_BASE, IMAGE_BASE
    dd 0, 6
    dd 0,0, 0,0, 0,0, 0,0, 0,0
    dd RELOC_VA, RELOC_VSZ
opt_end:

    db '.text',0,0,0
    dd TEXT_RAW, TEXT_VA, TEXT_RAW, HDR_SZ
    dd 0, 0
    dw 0, 0
    dd SECCHAR_TEXT

    db '.reloc',0,0
    dd RELOC_VSZ, RELOC_VA, RELOC_FSZ, RELOC_FOFF
    dd 0, 0
    dw 0, 0
    dd SECCHAR_RELOC

    times (HDR_SZ - ($ - $$)) db 0

; ============================================================================
; ENTRY  RCX=ImageHandle  RDX=SystemTable
; ============================================================================
_start:
    sub rsp, 40
    mov [v_handle], rcx
    mov [v_systab], rdx

    SER 'P'                                  ; P = probe start
    mov rax, [rdx + ST_BOOTSVC]
    mov [v_bs], rax
    mov rax, [rdx + ST_CONOUT]
    mov [v_conout], rax

    TRACE "T01: boot services + conout captured"

    ; Disable watchdog
    mov rcx, [v_bs]
    mov rax, [rcx + BS_WATCHDOG]
    xor ecx, ecx
    xor edx, edx
    xor r8d, r8d
    xor r9d, r9d
    call rax

    ; Reset console, disable hardware cursor (looks bad in graphics mode)
    mov rcx, [v_conout]
    mov rax, [rcx + CO_RESET]
    mov rcx, [v_conout]
    xor edx, edx
    call rax
    mov rcx, [v_conout]
    mov rax, [rcx + CO_ENABLECUR]
    mov rcx, [v_conout]
    xor edx, edx
    call rax

    TRACE "T02: watchdog off, console reset, cursor off"

    ; Print boot banner via UEFI text protocol
    lea rsi, [s_banner]
    call ucs_print
    call ucs_newline

    TRACE "T03: banner printed - about to locate GOP"

    SER 'G'
    call gop_init                             ; locate GOP, save framebuffer
    test rax, rax
    jnz no_gop_panic
    SER 'g'

    TRACE "T04: GOP located OK"

    ; Report GOP geometry
    lea rsi, [s_gop_res]
    call ucs_print
    mov edi, [v_scrw]
    call ucs_print_uint
    lea rsi, [s_x]
    call ucs_print
    mov edi, [v_scrh]
    call ucs_print_uint
    lea rsi, [s_pitch]
    call ucs_print
    mov edi, [v_pitch_pixels]
    call ucs_print_uint
    lea rsi, [s_fb]
    call ucs_print
    mov rdi, [v_fb]
    call ucs_print_hex64
    call ucs_newline

    lea rsi, [s_pixfmt]
    call ucs_print
    mov edi, [v_pixfmt]
    call ucs_print_uint
    lea rsi, [s_fbsize]
    call ucs_print
    mov rdi, [v_fbsize]
    call ucs_print_hex64
    call ucs_newline

    cmp dword [v_pixfmt], 3
    jne .pf_ok
    TRACE "T05: WARNING PixelFormat=3 (BltOnly) - NO linear framebuffer!"
.pf_ok:
    TRACE "T05: GOP geometry dumped (see pixfmt/fb above)"

    ; Use UEFI ConOut->ClearScreen instead of direct framebuffer wipe so the
    ; firmware's GraphicsConsole driver stays in sync. Set attribute to
    ; white-on-blue first for readability.
    mov rcx, [v_conout]
    mov rax, [rcx + CO_SETATTR]
    mov rcx, [v_conout]
    mov edx, 0x1F                             ; white on blue
    call rax
    mov rcx, [v_conout]
    mov rax, [rcx + CO_CLEAR]
    mov rcx, [v_conout]
    call rax

    ; Re-print banner after clear
    lea rsi, [s_banner]
    call ucs_print
    call ucs_newline
    lea rsi, [s_gop_res]
    call ucs_print
    mov edi, [v_scrw]
    call ucs_print_uint
    lea rsi, [s_x]
    call ucs_print
    mov edi, [v_scrh]
    call ucs_print_uint
    call ucs_newline

    TRACE "T06: screen cleared + reprinted - drawing TEST RECT now"

    ; --- TEST RECT: big green box at (300,300). If you see text below but
    ; NO green box, framebuffer writes are the problem (bad base/format). ---
    mov edi, 300
    mov esi, 300
    mov edx, 200
    mov ecx, 200
    mov r8d, COLOR_TEST_RECT_GREEN
    call fill_rect

    TRACE "T07: TEST RECT drawn - LOOK: is there a GREEN BOX on screen?"

    ; Initial cursor in middle of screen
    mov eax, [v_scrw]
    shr eax, 1
    mov [v_mx], eax
    mov eax, [v_scrh]
    shr eax, 1
    mov [v_my], eax

    TRACE "T08: probing SPP (LocateProtocol + handle enum)"
    SER 'S'
    lea rsi, [s_probing_spp]
    call ucs_print
    call ucs_newline
    call probe_spp_locate                     ; method 1
    SER 's'
    call probe_spp_enum                       ; method 2

    TRACE "T09: probing AbsolutePointer"
    SER 'A'
    lea rsi, [s_probing_app]
    call ucs_print
    call ucs_newline
    call probe_app_locate                     ; method 3
    SER 'a'
    call probe_app_enum                       ; method 4

    TRACE "T10: probing USB_IO"
    SER 'U'
    lea rsi, [s_probing_usb]
    call ucs_print
    call ucs_newline
    call probe_usb_io                         ; method 5: USB IO + sync interrupt
    SER 'u'

    TRACE "T11: probes done - drawing initial status row"

    lea rsi, [s_main_hdr]
    call ucs_print
    call ucs_newline

    ; Draw initial status row
    call draw_status_row

    TRACE "T12: ENTERING MAIN LOOP now"

    SDBG "probe: entering main loop"

; --- Main poll loop. Never exits. Never calls ExitBootServices. ---
; First 3 iterations are traced step-by-step so a hang inside the loop is
; pinpointed; after that it runs full speed so the mouse is responsive.
main_loop:
    cmp dword [v_frame], 3
    jae .t_a
    TRACE "L: top -> erase_cursor"
.t_a:
    call erase_cursor                         ; erase previous square
    cmp dword [v_frame], 3
    jae .t_b
    TRACE "L: -> poll_all_pointers"
.t_b:
    call poll_all_pointers                    ; updates v_mx/v_my and v_state
    cmp dword [v_frame], 3
    jae .t_c
    TRACE "L: -> usb_poll_mouse"
.t_c:
    call usb_poll_mouse                       ; slot 4: USB sync interrupt poll
    cmp dword [v_frame], 3
    jae .t_d
    TRACE "L: -> draw_cursor"
.t_d:
    call draw_cursor                          ; draw at new position
    cmp dword [v_frame], 3
    jae .t_e
    TRACE "L: -> draw_status_row"
.t_e:
    call draw_status_row                      ; refresh status dots
    cmp dword [v_frame], 3
    jae .t_f
    TRACE "L: -> draw_usb_panel"
.t_f:
    call draw_usb_panel                       ; big visible USB status block
    cmp dword [v_frame], 3
    jae .t_g
    TRACE "L: iteration complete - loop is alive"
.t_g:

    ; NO scrolling status text in the loop -- it pushed the probe results
    ; off-screen. Live state is shown graphically instead: the magenta cursor
    ; square moves, and draw_usb_panel shows the RC box (green=transfer OK,
    ; red=fail) + yellow HITS bar + report byte bars. Nothing scrolls.
    inc dword [v_frame]

    ; Stall ~10 ms
    mov rcx, [v_bs]
    mov rax, [rcx + BS_STALL]
    mov ecx, 10000                            ; microseconds
    call rax

    jmp main_loop

no_gop_panic:
    SDBG "FATAL: GOP unavailable"
.hang:
    hlt
    jmp .hang

; ============================================================================
; GOP_INIT - find GOP, take current mode, fill v_fb / v_scrw / v_scrh / v_pitch
; ============================================================================
gop_init:
    push rbx
    sub rsp, 32

    ; LocateProtocol(GOP_GUID, NULL, &v_gop)
    mov rax, [v_bs]
    mov rax, [rax + BS_LOCATE]
    lea rcx, [guid_gop]
    xor edx, edx
    lea r8, [v_gop]
    call rax
    test rax, rax
    jnz .gi_fail

    mov rbx, [v_gop]
    mov rax, [rbx + GOP_MODE]                 ; EFI_GRAPHICS_OUTPUT_PROTOCOL_MODE*
    ; Mode->Info is at offset 8 (UINT32 MaxMode, UINT32 Mode, EFI_GRAPHICS_OUTPUT_MODE_INFORMATION *Info, ...)
    ; We use the *current* mode info, do not change resolution.
    mov rcx, [rax + 8]                        ; Info ptr
    mov edx, [rcx + GOPI_HRES]
    mov [v_scrw], edx
    mov edx, [rcx + GOPI_VRES]
    mov [v_scrh], edx
    mov edx, [rcx + GOPI_PPSL]
    mov [v_pitch_pixels], edx
    mov edx, [rcx + 12]                       ; PixelFormat (0=RGB,1=BGR,2=mask,3=BltOnly)
    mov [v_pixfmt], edx

    mov rdx, [rax + GOPM_FBBASE]
    mov [v_fb], rdx
    mov rdx, [rax + 32]                       ; FrameBufferSize
    mov [v_fbsize], rdx

    xor eax, eax
    jmp .gi_done
.gi_fail:
    mov eax, 1
.gi_done:
    add rsp, 32
    pop rbx
    ret

; ============================================================================
; CLEAR_SCREEN_BG - blast a dark background across the entire framebuffer
; ============================================================================
clear_screen_bg:
    push rdi
    push rcx
    mov rdi, [v_fb]
    mov ecx, [v_pitch_pixels]
    imul ecx, [v_scrh]
    mov eax, COLOR_BG_DARK_SLATE              ; very dark blue-grey
    rep stosd
    pop rcx
    pop rdi
    ret

; ============================================================================
; PROBE_SPP_LOCATE - try LocateProtocol(SPP_GUID)
; Stores interface ptr in v_spp[0], success flag in v_spp_ok[0]
; ============================================================================
probe_spp_locate:
    push rbx
    sub rsp, 32
    mov rax, [v_bs]
    mov rax, [rax + BS_LOCATE]
    lea rcx, [guid_spp]
    xor edx, edx
    lea r8, [v_spp + 0]
    call rax
    mov [rsp+24], rax                         ; stash retcode
    test rax, rax
    jnz .pl_fail
    mov byte [v_spp_ok + 0], 1
    ; Reset device
    mov rbx, [v_spp + 0]
    mov rcx, rbx
    xor edx, edx                              ; ExtendedVerification = FALSE
    mov rax, [rbx + SPP_RESET]
    call rax
    SDBG "spp: LocateProtocol OK"
    lea rsi, [s_r_spp_loc_ok]
    call ucs_print
    mov rdi, [v_spp + 0]
    call ucs_print_hex64
    call ucs_newline
    jmp .pl_done
.pl_fail:
    SDBG "spp: LocateProtocol failed"
    lea rsi, [s_r_spp_loc_fail]
    call ucs_print
    mov rdi, [rsp+24]
    call ucs_print_hex64
    call ucs_newline
.pl_done:
    add rsp, 32
    pop rbx
    ret

; ============================================================================
; PROBE_SPP_ENUM - LocateHandleBuffer(SPP_GUID), then OpenProtocol on each
; until we find one that works. Stores in v_spp[1].
; ============================================================================
probe_spp_enum:
    push rbx
    push r12
    push r13
    sub rsp, 64
    ; [rsp+48] = num_handles
    ; [rsp+56] = handle_buffer

    mov qword [rsp+48], 0
    mov qword [rsp+56], 0

    mov rcx, [v_bs]
    mov rax, [rcx + BS_LOCHNDL]
    mov ecx, 2                                ; ByProtocol
    lea rdx, [guid_spp]
    xor r8d, r8d
    lea r9, [rsp+48]
    lea r10, [rsp+56]
    mov [rsp+32], r10
    call rax
    test rax, rax
    jnz .pe_fail
    mov r12, [rsp+48]
    test r12, r12
    jz .pe_fail
    mov r13, [rsp+56]                         ; handle array

    ; Print count
    lea rsi, [s_r_spp_enum_n]
    call ucs_print
    mov edi, r12d
    call ucs_print_uint
    call ucs_newline

.pe_try:
    test r12, r12
    jz .pe_fail

    ; OpenProtocol(handle, guid, &iface, imghandle, NULL, GET_PROTOCOL=2)
    mov rcx, [r13]
    mov rdx, [v_bs]
    mov rax, [rdx + BS_OPENPROT]
    lea rdx, [guid_spp]
    lea r8, [v_spp + 8]
    mov r9, [v_handle]
    mov qword [rsp+32], 0
    mov qword [rsp+40], 2
    call rax
    test rax, rax
    jnz .pe_next

    mov byte [v_spp_ok + 1], 1
    mov rbx, [v_spp + 8]
    mov rcx, rbx
    xor edx, edx
    mov rax, [rbx + SPP_RESET]
    call rax
    SDBG "spp: handle enum found one"
    lea rsi, [s_r_spp_enum_ok]
    call ucs_print
    mov rdi, [v_spp + 8]
    call ucs_print_hex64
    call ucs_newline
    jmp .pe_done

.pe_next:
    add r13, 8
    dec r12
    jmp .pe_try
.pe_fail:
    SDBG "spp: enum found none"
    lea rsi, [s_r_spp_enum_fail]
    call ucs_print
    call ucs_newline
.pe_done:
    add rsp, 64
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
; PROBE_APP_LOCATE - try LocateProtocol(AbsolutePointer)
; ============================================================================
probe_app_locate:
    push rbx
    sub rsp, 32
    mov rax, [v_bs]
    mov rax, [rax + BS_LOCATE]
    lea rcx, [guid_app]
    xor edx, edx
    lea r8, [v_app + 0]
    call rax
    mov [rsp+24], rax
    test rax, rax
    jnz .al_fail
    mov byte [v_app_ok + 0], 1
    mov rbx, [v_app + 0]
    mov rcx, rbx
    xor edx, edx
    mov rax, [rbx + APP_RESET]
    call rax
    SDBG "app: LocateProtocol OK"
    lea rsi, [s_r_app_loc_ok]
    call ucs_print
    mov rdi, [v_app + 0]
    call ucs_print_hex64
    call ucs_newline
    jmp .al_done
.al_fail:
    SDBG "app: LocateProtocol failed"
    lea rsi, [s_r_app_loc_fail]
    call ucs_print
    mov rdi, [rsp+24]
    call ucs_print_hex64
    call ucs_newline
.al_done:
    add rsp, 32
    pop rbx
    ret

; ============================================================================
; PROBE_APP_ENUM - LocateHandleBuffer + OpenProtocol for AbsolutePointer
; ============================================================================
probe_app_enum:
    push rbx
    push r12
    push r13
    sub rsp, 64

    mov qword [rsp+48], 0
    mov qword [rsp+56], 0

    mov rcx, [v_bs]
    mov rax, [rcx + BS_LOCHNDL]
    mov ecx, 2
    lea rdx, [guid_app]
    xor r8d, r8d
    lea r9, [rsp+48]
    lea r10, [rsp+56]
    mov [rsp+32], r10
    call rax
    test rax, rax
    jnz .ae_fail
    mov r12, [rsp+48]
    test r12, r12
    jz .ae_fail
    mov r13, [rsp+56]

    lea rsi, [s_r_app_enum_n]
    call ucs_print
    mov edi, r12d
    call ucs_print_uint
    call ucs_newline

.ae_try:
    test r12, r12
    jz .ae_fail

    mov rcx, [r13]
    mov rdx, [v_bs]
    mov rax, [rdx + BS_OPENPROT]
    lea rdx, [guid_app]
    lea r8, [v_app + 8]
    mov r9, [v_handle]
    mov qword [rsp+32], 0
    mov qword [rsp+40], 2
    call rax
    test rax, rax
    jnz .ae_next

    mov byte [v_app_ok + 1], 1
    mov rbx, [v_app + 8]
    mov rcx, rbx
    xor edx, edx
    mov rax, [rbx + APP_RESET]
    call rax
    SDBG "app: handle enum found one"
    lea rsi, [s_r_app_enum_ok]
    call ucs_print
    mov rdi, [v_app + 8]
    call ucs_print_hex64
    call ucs_newline
    jmp .ae_done

.ae_next:
    add r13, 8
    dec r12
    jmp .ae_try
.ae_fail:
    SDBG "app: enum found none"
    lea rsi, [s_r_app_enum_fail]
    call ucs_print
    call ucs_newline
.ae_done:
    add rsp, 64
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
; CHECK_INPUT_EVENT - RBX = SPP/APP iface. Reads WaitForInput EFI_EVENT at
; [RBX+16] and calls BS->CheckEvent (never blocks). Returns RAX=0 only when
; the event is signalled (GetState is then safe + fast). Returns RAX=1 when
; the event is NULL or not ready -> caller MUST skip GetState. This is what
; stops a blocking firmware GetState from freezing the probe.
; ============================================================================
check_input_event:
    push rcx
    push rdx
    push r8
    push r9
    push r10
    push r11
    mov rcx, [rbx + 16]                       ; WaitForInput event
    test rcx, rcx
    jz .cie_skip
    mov rax, [v_bs]
    mov rax, [rax + BS_CHECKEVT]
    sub rsp, 40
    call rax
    add rsp, 40
    test rax, rax
    jz .cie_done                              ; signalled -> RAX=0
.cie_skip:
    mov eax, 1
.cie_done:
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rcx
    ret

; ============================================================================
; POLL_ALL_POINTERS - call GetState on each found protocol, accumulate motion
; into v_mx/v_my, set v_state bits for activity blink.
; ============================================================================
poll_all_pointers:
    push rbx
    push r12
    sub rsp, 64                               ; state struct lives at [rsp+32..47]

    mov byte [v_state + 0], 0
    mov byte [v_state + 1], 0
    mov byte [v_state + 2], 0
    mov byte [v_state + 3], 0
    mov byte [v_state + 4], 0

    ; SPP/APP GetState is confirmed to BLOCK FOREVER on this firmware (it hangs
    ; even when CheckEvent reports the WaitForInput event as signalled). There
    ; is no safe way to call it. Disabled. Only usb_poll_mouse runs in the loop
    ; -- UsbSyncInterruptTransfer has a hard timeout and cannot hang.
    cmp byte [v_enable_sppapp], 0
    je .done

    ; --- SPP slot 0 ---
    cmp byte [v_spp_ok + 0], 0
    je .sp1
    mov rbx, [v_spp + 0]
    TRACEF "P: slot0 SPP-locate CheckEvent..."
    call check_input_event
    test rax, rax
    jnz .sp1
    TRACEF "P: slot0 SPP-locate -> GetState..."
    call call_spp_getstate
    mov [v_lastret + 0*8], rax
    test rax, rax
    jnz .sp1
    mov byte [v_state + 0], 1
    inc dword [v_hits + 0*4]
    call apply_relative_motion

.sp1:
    cmp byte [v_spp_ok + 1], 0
    je .ap0
    mov rbx, [v_spp + 8]
    TRACEF "P: slot1 SPP-enum CheckEvent..."
    call check_input_event
    test rax, rax
    jnz .ap0
    TRACEF "P: slot1 SPP-enum -> GetState..."
    call call_spp_getstate
    mov [v_lastret + 1*8], rax
    test rax, rax
    jnz .ap0
    mov byte [v_state + 1], 1
    inc dword [v_hits + 1*4]
    call apply_relative_motion

.ap0:
    cmp byte [v_app_ok + 0], 0
    je .ap1
    mov rbx, [v_app + 0]
    TRACEF "P: slot2 APP-locate CheckEvent..."
    call check_input_event
    test rax, rax
    jnz .ap1
    TRACEF "P: slot2 APP-locate -> GetState..."
    call call_app_getstate
    mov [v_lastret + 2*8], rax
    test rax, rax
    jnz .ap1
    mov byte [v_state + 2], 1
    inc dword [v_hits + 2*4]
    call apply_absolute_motion

.ap1:
    cmp byte [v_app_ok + 1], 0
    je .done
    mov rbx, [v_app + 8]
    TRACEF "P: slot3 APP-enum CheckEvent..."
    call check_input_event
    test rax, rax
    jnz .done
    TRACEF "P: slot3 APP-enum -> GetState..."
    call call_app_getstate
    mov [v_lastret + 3*8], rax
    test rax, rax
    jnz .done
    mov byte [v_state + 3], 1
    inc dword [v_hits + 3*4]
    call apply_absolute_motion

.done:
    TRACEF "P: SPP/APP polling skipped - USB-only mode"
    add rsp, 64
    pop r12
    pop rbx
    ret

; ----- Helpers used by poll_all_pointers, with state on [rsp+32..47] -----
; EFI_SIMPLE_POINTER_STATE = { INT32 RelX, RelY, RelZ; BOOL LeftBtn; BOOL RightBtn }
call_spp_getstate:
    mov rcx, rbx                              ; this
    lea rdx, [rsp+32]
    ; Zero state buffer
    xor eax, eax
    mov [rsp+32], eax
    mov [rsp+36], eax
    mov [rsp+40], eax
    mov [rsp+44], eax
    mov rax, [rbx + SPP_GETSTATE]
    call rax
    ret

apply_relative_motion:
    mov eax, [rsp+32]                         ; RelativeMovementX
    sar eax, 1                                ; halve to avoid mach-speed cursor
    add [v_mx], eax
    mov eax, [rsp+36]
    sar eax, 1
    add [v_my], eax
    call clamp_cursor
    ret

; EFI_ABSOLUTE_POINTER_STATE = { UINT64 CurrentX, CurrentY, CurrentZ; UINT32 ActiveButtons }
call_app_getstate:
    mov rcx, rbx
    lea rdx, [rsp+32]
    xor eax, eax
    mov [rsp+32], eax
    mov [rsp+36], eax
    mov [rsp+40], eax
    mov [rsp+44], eax
    mov [rsp+48], eax
    mov [rsp+52], eax
    mov [rsp+56], eax
    mov [rsp+60], eax
    mov rax, [rbx + APP_GETSTATE]
    call rax
    ret

; Map absolute coords (0..AbsoluteMaxX) to screen. We do not know the max
; without reading Mode, so as a first cut just clip the low 32 bits and
; assume the firmware reports in screen pixels (true for many touchscreens
; that match GOP resolution). If not, the cursor will still move - just
; at the wrong scale, which is enough to confirm the path works.
apply_absolute_motion:
    ; UEFI AbsolutePointer returns EFI_SUCCESS with X=Y=Buttons=0 when the
    ; touchpad has no contact. Treat all-zeros as "no event" so the cursor
    ; doesn't get yanked to (0,0) and hidden behind the status row.
    mov eax, [rsp+32]
    or eax, [rsp+40]
    or eax, [rsp+56]                          ; ActiveButtons
    jz .am_skip
    mov eax, [rsp+32]                         ; CurrentX low 32
    mov [v_mx], eax
    mov eax, [rsp+40]                         ; CurrentY low 32
    mov [v_my], eax
    call clamp_cursor
.am_skip:
    ret

clamp_cursor:
    mov eax, [v_mx]
    test eax, eax
    jns .cx_ok
    xor eax, eax
.cx_ok:
    mov edx, [v_scrw]
    sub edx, 20
    cmp eax, edx
    jle .cx_store
    mov eax, edx
.cx_store:
    mov [v_mx], eax
    mov eax, [v_my]
    test eax, eax
    jns .cy_ok
    xor eax, eax
.cy_ok:
    mov edx, [v_scrh]
    sub edx, 20
    cmp eax, edx
    jle .cy_store
    mov eax, edx
.cy_store:
    mov [v_my], eax
    ret

; ============================================================================
; DRAW_CURSOR / ERASE_CURSOR  - 16x16 square at (v_mx, v_my). Erase records
; previous position so we can write black over it next frame.
; ============================================================================
draw_cursor:
    mov eax, [v_mx]
    mov [v_prev_mx], eax
    mov eax, [v_my]
    mov [v_prev_my], eax
    mov edi, [v_mx]
    mov esi, [v_my]
    mov edx, 20
    mov ecx, 20
    mov r8d, COLOR_CURSOR_MAGENTA             ; bright magenta
    call fill_rect
    ret

erase_cursor:
    mov edi, [v_prev_mx]
    mov esi, [v_prev_my]
    mov edx, 20
    mov ecx, 20
    mov r8d, COLOR_BG_UEFI_BLUE               ; UEFI EFI_BACKGROUND_BLUE (BGRA)
    call fill_rect
    ret

; ============================================================================
; DRAW_STATUS_ROW - four 12x12 squares along the top edge:
; slot 0 (spp locate), 1 (spp enum), 2 (app locate), 3 (app enum)
;   not found  -> dim grey
;   found, idle-> medium colour
;   found, active GetState this frame -> bright + 16px wide
; ============================================================================
draw_status_row:
    ; slot 0
    xor edi, edi
    add edi, 8
    mov esi, 4
    cmp byte [v_spp_ok + 0], 0
    je .s0_off
    mov r8d, COLOR_DARK_RED                   ; dark red
    cmp byte [v_state + 0], 0
    je .s0_paint
    mov r8d, COLOR_BRIGHT_RED                 ; bright red
.s0_paint:
    jmp .s0_do
.s0_off:
    mov r8d, COLOR_DIM_GREY
.s0_do:
    mov edx, 14
    mov ecx, 14
    call fill_rect

    ; slot 1
    mov edi, 28
    mov esi, 4
    cmp byte [v_spp_ok + 1], 0
    je .s1_off
    mov r8d, COLOR_DARK_ORANGE
    cmp byte [v_state + 1], 0
    je .s1_paint
    mov r8d, COLOR_BRIGHT_ORANGE
.s1_paint:
    jmp .s1_do
.s1_off:
    mov r8d, COLOR_DIM_GREY
.s1_do:
    mov edx, 14
    mov ecx, 14
    call fill_rect

    ; slot 2
    mov edi, 48
    mov esi, 4
    cmp byte [v_app_ok + 0], 0
    je .s2_off
    mov r8d, COLOR_DARK_GREEN
    cmp byte [v_state + 2], 0
    je .s2_paint
    mov r8d, COLOR_BRIGHT_GREEN
.s2_paint:
    jmp .s2_do
.s2_off:
    mov r8d, COLOR_DIM_GREY
.s2_do:
    mov edx, 14
    mov ecx, 14
    call fill_rect

    ; slot 3
    mov edi, 68
    mov esi, 4
    cmp byte [v_app_ok + 1], 0
    je .s3_off
    mov r8d, COLOR_DARK_CYAN
    cmp byte [v_state + 3], 0
    je .s3_paint
    mov r8d, COLOR_BRIGHT_CYAN
.s3_paint:
    jmp .s3_do
.s3_off:
    mov r8d, COLOR_DIM_GREY
.s3_do:
    mov edx, 14
    mov ecx, 14
    call fill_rect

    ; slot 4 (USB IO) -- yellow
    mov edi, 88
    mov esi, 4
    cmp byte [v_usb_ok], 0
    je .s4_off
    mov r8d, COLOR_DARK_YELLOW
    cmp byte [v_state + 4], 0
    je .s4_paint
    mov r8d, COLOR_YELLOW
.s4_paint:
    jmp .s4_do
.s4_off:
    mov r8d, COLOR_DIM_GREY
.s4_do:
    mov edx, 14
    mov ecx, 14
    call fill_rect
    ret

; ============================================================================
; DRAW_USB_PANEL - big, unambiguous on-screen indicator of USB transfer state.
; Layout (top of screen, x=150..950, y=4..100):
;   y=4..28   : RC SQUARE.  Green = last UsbSyncInterruptTransfer returned 0.
;               Red = nonzero (failure or timeout). 24 px tall, 100 px wide.
;   y=4..28   : HITS BAR.  To the right of RC square. Width grows by ~1 px per
;               transfer success.  Wraps every 700 px.  Just confirms the call
;               is being made successfully when you wiggle.
;   y=34..58  : Four colored byte-bars (white,red,green,cyan) for first 4
;               bytes of the most recent non-empty report, length = byte*4.
;   y=64..88  : USB rc as 16 hex nibbles rendered as little colored squares
;               so we can read the exact failure code without ConOut.
; ============================================================================
draw_usb_panel:
    ; ---- clear strip ----
    mov edi, 150
    mov esi, 4
    mov edx, 800
    mov ecx, 96
    mov r8d, COLOR_PANEL_BG
    call fill_rect

    ; ---- RC square ----
    mov rax, [v_lastret + 4*8]
    test rax, rax
    jnz .rc_bad
    mov r8d, COLOR_RC_GREEN                    ; green
    jmp .rc_paint
.rc_bad:
    mov r8d, COLOR_RC_RED                      ; red
.rc_paint:
    mov edi, 150
    mov esi, 4
    mov edx, 100
    mov ecx, 24
    call fill_rect

    ; ---- HITS bar ----
    mov eax, [v_hits + 4*4]
    and eax, 0x3FF                            ; wrap at 1024
    test eax, eax
    jnz .hb_go
    mov eax, 2
.hb_go:
    mov edx, eax
    mov edi, 260
    mov esi, 4
    mov ecx, 24
    mov r8d, COLOR_YELLOW                      ; yellow
    call fill_rect

    ; ---- byte bars (4 stacked) ----
    mov eax, [v_last_report]
    mov [drb_tmp], eax

    ; b0 white
    movzx eax, byte [drb_tmp + 0]
    imul eax, 4
    test eax, eax
    jnz .b0g
    mov eax, 2
.b0g:
    mov edx, eax
    mov edi, 150
    mov esi, 34
    mov ecx, 5
    mov r8d, COLOR_WHITE
    call fill_rect

    ; b1 red (signed)
    movzx eax, byte [drb_tmp + 1]
    test al, 0x80
    jz .b1p
    neg al
.b1p:
    movzx eax, al
    imul eax, 6
    test eax, eax
    jnz .b1g
    mov eax, 2
.b1g:
    mov edx, eax
    mov edi, 150
    mov esi, 40
    mov ecx, 5
    mov r8d, COLOR_BAR_RED
    call fill_rect

    ; b2 green (signed)
    movzx eax, byte [drb_tmp + 2]
    test al, 0x80
    jz .b2p
    neg al
.b2p:
    movzx eax, al
    imul eax, 6
    test eax, eax
    jnz .b2g
    mov eax, 2
.b2g:
    mov edx, eax
    mov edi, 150
    mov esi, 46
    mov ecx, 5
    mov r8d, COLOR_BAR_GREEN
    call fill_rect

    ; b3 cyan (signed)
    movzx eax, byte [drb_tmp + 3]
    test al, 0x80
    jz .b3p
    neg al
.b3p:
    movzx eax, al
    imul eax, 6
    test eax, eax
    jnz .b3g
    mov eax, 2
.b3g:
    mov edx, eax
    mov edi, 150
    mov esi, 52
    mov ecx, 5
    mov r8d, COLOR_BAR_CYAN
    call fill_rect

    ; ---- rc as 16 hex nibbles ----
    ; each nibble = 24x24 box. brightness proportional to value 0..15.
    ; Nibbles are drawn MSB->LSB left to right.
    mov rax, [v_lastret + 4*8]
    mov rbx, rax
    mov ecx, 16
    mov r10d, 150                              ; x cursor
.nb_loop:
    rol rbx, 4
    mov edx, ebx
    and edx, 0xF
    mov eax, edx
    shl eax, 4                                 ; *16 → 0..240 brightness
    mov r11d, eax
    shl eax, 8
    or r11d, eax
    shl eax, 8
    or r11d, eax                               ; rgb gray ramp
    push rcx
    push r10
    mov edi, r10d
    mov esi, 64
    mov edx, 22
    mov ecx, 22
    mov r8d, r11d
    call fill_rect
    pop r10
    pop rcx
    add r10d, 26
    dec ecx
    jnz .nb_loop

    ; ---- RAW async-callback indicator: huge box low on screen ----
    ; BRIGHT CYAN  = usb_cb has fired at least once (firmware IS delivering
    ;                HID reports to us -> the async path works).
    ; DARK GREY    = usb_cb has NEVER fired (firmware accepted the transfer
    ;                but never calls our callback).
    mov eax, [usb_async_hits]
    test eax, eax
    jz .cbi_dark
    mov r8d, COLOR_BRIGHT_CYAN
    jmp .cbi_draw
.cbi_dark:
    mov r8d, COLOR_CB_DARK_GREY
.cbi_draw:
    mov edi, 1340                             ; far right, clear of the text
    mov esi, 130
    mov edx, 560
    mov ecx, 300
    call fill_rect

    ; magenta width-bar under it = raw callback count (1px each, wraps 1100)
    mov eax, [usb_async_hits]
    xor edx, edx
    mov ecx, 560
    div ecx
    test edx, edx
    jnz .cbi_bar
    mov edx, 4
.cbi_bar:
    mov edi, 1340
    mov esi, 450
    mov ecx, 40
    mov r8d, COLOR_CURSOR_MAGENTA
    call fill_rect
    ret

; ============================================================================
; OLD report bars (DEAD CODE - replaced by draw_usb_panel above)
; ============================================================================
old_draw_report_bars_dead:
    ; Background strip
    mov edi, 110
    mov esi, 4
    mov edx, 800
    mov ecx, 44
    mov r8d, COLOR_BLACK
    call fill_rect

    mov eax, [v_last_report]
    mov [drb_tmp], eax

    ; byte 0 - white
    movzx eax, byte [drb_tmp + 0]
    imul eax, 3
    mov edx, eax
    test edx, edx
    jnz .drb0_go
    mov edx, 2
.drb0_go:
    mov edi, 110
    mov esi, 6
    mov ecx, 8
    mov r8d, COLOR_WHITE
    call fill_rect

    ; byte 1 - red (this is dx in boot layout)
    movzx eax, byte [drb_tmp + 1]
    ; treat as signed magnitude for display
    test al, 0x80
    jz .drb1_pos
    neg al
.drb1_pos:
    movzx eax, al
    imul eax, 4
    mov edx, eax
    test edx, edx
    jnz .drb1_go
    mov edx, 2
.drb1_go:
    mov edi, 110
    mov esi, 16
    mov ecx, 8
    mov r8d, COLOR_BAR_RED
    call fill_rect

    ; byte 2 - green (this is dy in boot layout, OR dx if report ID present)
    movzx eax, byte [drb_tmp + 2]
    test al, 0x80
    jz .drb2_pos
    neg al
.drb2_pos:
    movzx eax, al
    imul eax, 4
    mov edx, eax
    test edx, edx
    jnz .drb2_go
    mov edx, 2
.drb2_go:
    mov edi, 110
    mov esi, 26
    mov ecx, 8
    mov r8d, COLOR_BAR_GREEN
    call fill_rect

    ; byte 3 - cyan (dy if report ID present, or wheel)
    movzx eax, byte [drb_tmp + 3]
    test al, 0x80
    jz .drb3_pos
    neg al
.drb3_pos:
    movzx eax, al
    imul eax, 4
    mov edx, eax
    test edx, edx
    jnz .drb3_go
    mov edx, 2
.drb3_go:
    mov edi, 110
    mov esi, 36
    mov ecx, 8
    mov r8d, COLOR_BAR_CYAN
    call fill_rect
    ret

; ============================================================================
; FILL_RECT  EDI=x  ESI=y  EDX=w  ECX=h  R8D=ARGB
; ============================================================================
fill_rect:
    push rax
    push rbx
    push rdi
    push rsi
    push r9
    push r10
    push r11

    mov r9d, [v_pitch_pixels]
    mov rbx, [v_fb]
    ; rdi = fb + (y * pitch + x) * 4
    mov eax, esi
    imul eax, r9d
    add eax, edi
    shl rax, 2
    add rbx, rax
    mov r10d, ecx                              ; row counter
.fr_row:
    test r10d, r10d
    jz .fr_done
    mov r11d, edx                              ; col counter
    mov rdi, rbx
.fr_col:
    test r11d, r11d
    jz .fr_next
    mov [rdi], r8d
    add rdi, 4
    dec r11d
    jmp .fr_col
.fr_next:
    mov eax, r9d
    shl eax, 2
    add rbx, rax
    dec r10d
    jmp .fr_row
.fr_done:
    pop r11
    pop r10
    pop r9
    pop rsi
    pop rdi
    pop rbx
    pop rax
    ret

; ============================================================================
; PROBE_USB_IO - enumerate USB_IO handles, find HID class=3 protocol=2 (mouse),
; pick its IN interrupt endpoint, send SET_PROTOCOL(boot=0).
; ============================================================================
probe_usb_io:
    push rbx
    push r12
    push r13
    push r14
    push r15
    sub rsp, 80
    ; locals (5 pushes = 0 mod 16, +80 still 0 mod 16; calls land aligned)
    ;   [rsp+48] num_handles
    ;   [rsp+56] handle_buffer ptr (filled by LocateHandleBuffer)

    mov qword [rsp+48], 0
    mov qword [rsp+56], 0

    mov rcx, [v_bs]
    mov rax, [rcx + BS_LOCHNDL]
    mov ecx, 2                                ; ByProtocol
    lea rdx, [guid_usbio]
    xor r8d, r8d
    lea r9, [rsp+48]
    lea r10, [rsp+56]
    mov [rsp+32], r10
    call rax
    test rax, rax
    jnz .pu_fail

    mov r12, [rsp+48]
    test r12, r12
    jz .pu_fail
    mov r13, [rsp+56]

    SDBG "usb_io: scanning handles"
    lea rsi, [s_r_usb_n]
    call ucs_print
    mov edi, r12d
    call ucs_print_uint
    call ucs_newline

.pu_try:
    test r12, r12
    jz .pu_fail

    ; OpenProtocol(handle, guid_usbio, &iface, imghandle, NULL, GET=2)
    ; NOTE: We deliberately do NOT call DisconnectController here. On Acer
    ; AMD firmware that hangs the xHCI host driver and the whole loop dies.
    ; We accept shared access and read whatever the firmware HID driver
    ; leaves available.
    mov rcx, [r13]
    mov rdx, [v_bs]
    mov rax, [rdx + BS_OPENPROT]
    lea rdx, [guid_usbio]
    lea r8, [v_usb_io]
    mov r9, [v_handle]
    mov qword [rsp+32], 0
    mov qword [rsp+40], 2
    call rax
    test rax, rax
    jnz .pu_next

    ; UsbGetInterfaceDescriptor(this, &usb_if_desc)  vtbl[64]
    mov rbx, [v_usb_io]
    mov rcx, rbx
    lea rdx, [usb_if_desc]
    mov rax, [rbx + 64]
    call rax
    test rax, rax
    jnz .pu_next

    ; Class==3 (HID)?  Accept ANY protocol except 1 (keyboard) -- we may have
    ; matched the wrong device before, so arm every HID pointer interface.
    movzx eax, byte [usb_if_desc + 5]
    cmp al, 3
    jne .pu_next
    movzx eax, byte [usb_if_desc + 7]
    cmp al, 1                                  ; protocol 1 = keyboard, skip
    je .pu_next

    ; iterate endpoints to find IN interrupt
    movzx r14d, byte [usb_if_desc + 4]        ; BNumEndpoints
    xor r15d, r15d
.pu_ep_loop:
    cmp r15d, r14d
    jge .pu_next
    mov rcx, rbx
    mov edx, r15d
    lea r8, [usb_ep_desc]
    mov rax, [rbx + 72]
    call rax
    test rax, rax
    jnz .pu_ep_next
    movzx eax, byte [usb_ep_desc + 3]         ; BmAttributes
    and al, 3
    cmp al, 3                                  ; INTERRUPT
    jne .pu_ep_next
    movzx eax, byte [usb_ep_desc + 2]         ; BEndpointAddress
    test al, 0x80                              ; IN
    jz .pu_ep_next

    ; Capture
    mov [v_usb_ep], al
    movzx eax, byte [usb_ep_desc + 6]
    mov [v_usb_interval], al
    movzx eax, word [usb_ep_desc + 4]         ; wMaxPacketSize
    mov [v_usb_maxpkt], ax
    movzx eax, byte [usb_ep_desc + 3]         ; bmAttributes
    mov [v_usb_epattr], al
    movzx eax, byte [usb_if_desc + 2]
    mov [v_usb_iface_num], al
    movzx eax, byte [usb_if_desc + 4]
    mov [v_usb_numep], al
    mov byte [v_usb_ok], 1

    ; Dump exactly what device/endpoint we matched
    lea rsi, [s_d_iface]
    call ucs_print
    movzx edi, byte [v_usb_iface_num]
    call ucs_print_uint
    lea rsi, [s_d_ep]
    call ucs_print
    movzx edi, byte [v_usb_ep]
    call ucs_print_uint
    lea rsi, [s_d_attr]
    call ucs_print
    movzx edi, byte [v_usb_epattr]
    call ucs_print_uint
    lea rsi, [s_d_mps]
    call ucs_print
    movzx edi, word [v_usb_maxpkt]
    call ucs_print_uint
    lea rsi, [s_d_ivl]
    call ucs_print
    movzx edi, byte [v_usb_interval]
    call ucs_print_uint
    call ucs_newline

    ; --- Detach the firmware's own HID driver from this interface so WE own
    ; the interrupt endpoint. Without this the firmware accepts our async
    ; transfer but never services it (callback box stayed grey).
    ; DisconnectController(ControllerHandle, DriverImageHandle=NULL, Child=NULL)
    TRACE "T-disc: calling DisconnectController on HID iface..."
    mov rcx, [r13]
    xor edx, edx
    xor r8d, r8d
    mov rax, [v_bs]
    mov rax, [rax + BS_DISCONN]
    call rax
    mov [v_usb_disc_ret], rax
    lea rsi, [s_r_usb_disc]
    call ucs_print
    mov rdi, [v_usb_disc_ret]
    call ucs_print_hex64
    call ucs_newline
    TRACE "T-disc: DisconnectController returned OK"

    ; Send SET_PROTOCOL(0=boot) via UsbControlTransfer
    ; bmRequestType=0x21, bRequest=0x0B, wValue=0, wIndex=iface, wLength=0
    mov byte  [usb_setup_pkt + 0], 0x21
    mov byte  [usb_setup_pkt + 1], 0x0B
    mov word  [usb_setup_pkt + 2], 0
    mov al, [v_usb_iface_num]
    mov [usb_setup_pkt + 4], al
    mov byte  [usb_setup_pkt + 5], 0
    mov word  [usb_setup_pkt + 6], 0

    mov rbx, [v_usb_io]
    mov rcx, rbx
    lea rdx, [usb_setup_pkt]
    mov r8d, 2                                 ; EfiUsbNoData = 2 (0=DataIn,1=DataOut,2=NoData)
    mov r9d, 100                               ; Timeout 100 ms
    mov qword [rsp+32], 0                      ; Data = NULL
    mov qword [rsp+40], 0                      ; DataLength = 0
    lea rax, [usb_xfer_status]
    mov [rsp+48], rax                          ; *Status
    mov rax, [rbx + 0]                         ; UsbControlTransfer
    call rax

    lea rsi, [s_r_usb_setproto]
    call ucs_print
    mov rdi, rax
    call ucs_print_hex64
    call ucs_newline

    ; Send SET_IDLE(duration=0). The kernel USB driver does this too -- some
    ; mice will not send reports until idle throttling is cleared.
    ; bmRequestType=0x21, bRequest=0x0A, wValue=0, wIndex=iface, wLength=0
    mov byte  [usb_setup_pkt + 0], 0x21
    mov byte  [usb_setup_pkt + 1], 0x0A
    mov word  [usb_setup_pkt + 2], 0
    mov al, [v_usb_iface_num]
    mov [usb_setup_pkt + 4], al
    mov byte  [usb_setup_pkt + 5], 0
    mov word  [usb_setup_pkt + 6], 0
    mov rbx, [v_usb_io]
    mov rcx, rbx
    lea rdx, [usb_setup_pkt]
    mov r8d, 2
    mov r9d, 100
    mov qword [rsp+32], 0
    mov qword [rsp+40], 0
    lea rax, [usb_xfer_status]
    mov [rsp+48], rax
    mov rax, [rbx + 0]
    call rax

    SDBG "usb_io: found HID mouse"
    lea rsi, [s_r_usb_ok]
    call ucs_print
    movzx edi, byte [v_usb_ep]
    call ucs_print_hex64
    call ucs_newline

    ; --- Register an ASYNC interrupt transfer.  This is the documented HID
    ; input path: the firmware polls the endpoint and invokes usb_cb for each
    ; report.  It uses a different firmware code path than Sync transfer, so
    ; if Sync returns EFI_INVALID_PARAMETER this may still deliver data.
    mov rbx, [v_usb_io]
    mov rcx, rbx
    movzx rdx, byte [v_usb_ep]
    mov r8d, 1                                ; IsNewTransfer = TRUE
    mov r9d, 8                                ; PollingInterval = 8 ms
    movzx rax, word [v_usb_maxpkt]
    test rax, rax
    jnz .pu_mp
    mov eax, 8
.pu_mp:
    cmp rax, 16
    jbe .pu_mp2
    mov eax, 16
.pu_mp2:
    mov [rsp+32], rax                         ; DataLength
    lea rax, [usb_cb]
    mov [rsp+40], rax                         ; InterruptCallBack
    mov qword [rsp+48], 0                     ; Context = NULL
    mov rax, [rbx + 16]                       ; UsbAsyncInterruptTransfer
    call rax
    mov [v_usb_async_ret], rax

    lea rsi, [s_r_usb_async]
    call ucs_print
    mov rdi, rax
    call ucs_print_hex64
    call ucs_newline

    ; Armed this interface. Keep scanning -- arm EVERY HID pointer interface
    ; so we cannot miss the real mouse by picking the wrong handle.
    inc dword [v_usb_found]
    jmp .pu_next

.pu_ep_next:
    inc r15d
    jmp .pu_ep_loop

.pu_next:
    add r13, 8
    dec r12
    jmp .pu_try

.pu_fail:
    cmp dword [v_usb_found], 0
    jne .pu_done
    SDBG "usb_io: no HID mouse"
    lea rsi, [s_r_usb_fail]
    call ucs_print
    call ucs_newline
.pu_done:
    add rsp, 80
    pop r15
    pop r14
    pop r13
    pop r12
    pop rbx
    ret

; ============================================================================
; USB_CB - EFIAPI callback for UsbAsyncInterruptTransfer.
;   RCX=Data  RDX=DataLength  R8=Context  R9=Status
; Runs at TPL_NOTIFY during BS->Stall. Just copies the report and bumps a
; counter -- no firmware calls, so it cannot block or recurse.
; ============================================================================
usb_cb:
    push rsi
    push rdi
    test rcx, rcx
    jz .cb_done
    mov rsi, rcx
    lea rdi, [usb_async_buf]
    mov rcx, rdx
    cmp rcx, 16
    jbe .cb_len
    mov ecx, 16
.cb_len:
    test rcx, rcx
    jz .cb_done
    rep movsb
    mov eax, [usb_async_buf]
    mov [usb_async_report], eax
    inc dword [usb_async_hits]
.cb_done:
    pop rdi
    pop rsi
    xor eax, eax
    ret

; ============================================================================
; USB_POLL_MOUSE  - process async-delivered reports, then do one
; UsbSyncInterruptTransfer. Either path moves the cursor.
; ============================================================================
usb_poll_mouse:
    cmp byte [v_usb_ok], 0
    je .uq_ret

    ; --- ASYNC path: did usb_cb deliver a new report since last frame? ---
    mov eax, [usb_async_hits]
    cmp eax, [v_async_seen]
    je .uq_sync
    mov [v_async_seen], eax
    mov byte [v_state + 4], 1
    inc dword [v_hits + 4*4]
    mov eax, [usb_async_report]
    test eax, eax
    jz .uq_sync
    mov [v_last_report], eax
    movsx ecx, byte [usb_async_report + 1]     ; boot mouse dx
    movsx edx, byte [usb_async_report + 2]     ; boot mouse dy
    add [v_mx], ecx
    add [v_my], edx
    call clamp_cursor
.uq_sync:

    push rbx
    sub rsp, 64                                ; (1 push) entry 8mod16, +8+64=72 → 0mod16
    ; [rsp+0..31] shadow ; [rsp+32]=Timeout ; [rsp+40]=*Status ; [rsp+48]=DataLength

    ; DataLength MUST match the endpoint's wMaxPacketSize for an interrupt
    ; transfer -- sending 8 when maxpkt=5 is what made the firmware return
    ; EFI_INVALID_PARAMETER. Use the captured maxpkt.
    movzx rax, word [v_usb_maxpkt]
    test rax, rax
    jnz .mp_ok
    mov eax, 8
.mp_ok:
    cmp rax, 16
    jbe .mp_ok2
    mov eax, 16
.mp_ok2:
    mov [rsp+48], rax
    mov qword [usb_report_buf], 0
    mov dword [usb_xfer_status], 0

    mov rbx, [v_usb_io]
    mov rcx, rbx
    movzx rdx, byte [v_usb_ep]
    lea r8, [usb_report_buf]
    lea r9, [rsp+48]
    mov qword [rsp+32], 20                     ; 20 ms timeout (catch one report)
    lea rax, [usb_xfer_status]
    mov [rsp+40], rax
    mov rax, [rbx + 24]                        ; UsbSyncInterruptTransfer
    call rax

    mov [v_lastret + 4*8], rax
    test rax, rax
    jnz .uq_no
    cmp qword [rsp+48], 0
    je .uq_no

    mov byte [v_state + 4], 1
    inc dword [v_hits + 4*4]

    ; Snapshot first 4 bytes for the on-screen byte-bars (set v_last_report
    ; only when nonzero so we keep the *last motion* visible after a stop)
    mov eax, [usb_report_buf]
    test eax, eax
    jz .uq_apply
    mov [v_last_report], eax

.uq_apply:
    ; Try boot layout first: byte1=dx, byte2=dy.  If both are zero AND
    ; byte0 itself isn't a typical button mask (high bits set), shift over
    ; by one to handle report-ID-prefixed devices (byte0=ID, b2=dx, b3=dy).
    movsx ecx, byte [usb_report_buf + 1]
    movsx edx, byte [usb_report_buf + 2]
    mov eax, ecx
    or eax, edx
    jnz .uq_use_boot
    movsx ecx, byte [usb_report_buf + 2]
    movsx edx, byte [usb_report_buf + 3]
.uq_use_boot:
    add [v_mx], ecx
    add [v_my], edx
    call clamp_cursor

.uq_no:
    add rsp, 64
    pop rbx
.uq_ret:
    ret

; ============================================================================
; TEXT OUTPUT HELPERS - UEFI ConOut wrappers (UCS-2)
; ============================================================================
; ucs_print: RSI = UCS-2 null-terminated string
ucs_print:
    push rax
    push rcx
    push rdx
    push r8
    push r9
    push r10
    push r11
    mov rcx, [v_conout]
    mov rax, [rcx + CO_OUTPUT]
    mov rcx, [v_conout]
    mov rdx, rsi
    call rax
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdx
    pop rcx
    pop rax
    ret

; ucs_newline
ucs_newline:
    push rsi
    lea rsi, [s_crlf_real]
    call ucs_print
    pop rsi
    ret

; trace_step: RSI = UCS-2 string. Print it + newline, then stall so the user
; can read each step. Used by the TRACE macro.
trace_step:
    push rdi
    push rsi
    call ucs_print
    call ucs_newline
    mov rcx, [v_bs]
    mov rax, [rcx + BS_STALL]
    mov ecx, [g_trace_stall_us]
    sub rsp, 40
    call rax
    add rsp, 40
    pop rsi
    pop rdi
    ret

; ucs_print_uint: EDI = uint32 to print as decimal
ucs_print_uint:
    push rax
    push rcx
    push rdx
    push rdi
    push rsi
    push rbx
    push r10
    lea r10, [num_buf]                        ; UCS-2 buffer
    mov eax, edi
    xor ecx, ecx                              ; digit count
    mov ebx, 10
.upu_div:
    xor edx, edx
    div ebx
    add dl, '0'
    mov [num_scratch + rcx], dl
    inc ecx
    test eax, eax
    jnz .upu_div
    ; reverse into UCS-2 buffer
    xor edx, edx                              ; out idx
.upu_emit:
    test ecx, ecx
    jz .upu_done
    dec ecx
    movzx eax, byte [num_scratch + rcx]
    mov [r10 + rdx*2], ax
    inc edx
    jmp .upu_emit
.upu_done:
    mov word [r10 + rdx*2], 0
    mov rsi, r10
    call ucs_print
    pop r10
    pop rbx
    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rax
    ret

; ucs_print_hex64: RDI = uint64 to print as 16 hex digits (no prefix)
ucs_print_hex64:
    push rax
    push rbx
    push rcx
    push rdx
    push rsi
    push r10
    lea r10, [num_buf]
    mov rax, rdi
    mov ecx, 16
    xor edx, edx
.uph_loop:
    rol rax, 4                                ; bring top nibble to bottom
    mov ebx, eax
    and ebx, 0xF
    add bl, '0'
    cmp bl, '9'
    jbe .uph_store
    add bl, 7                                 ; 'A'..'F'
.uph_store:
    movzx ebx, bl
    mov [r10 + rdx*2], bx
    inc edx
    dec ecx
    jnz .uph_loop
    mov word [r10 + rdx*2], 0
    mov rsi, r10
    call ucs_print
    pop r10
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    pop rax
    ret

; ============================================================================
; PRINT_STATUS_LINE - reset cursor to row 8, print live diagnostic
; Pattern (fixed width so each refresh overwrites cleanly):
;   ret0=XXXXXXXXXXXXXXXX ret1=... ret2=... ret3=...
;   hits0=NNNNN hits1=... hits2=... hits3=... mx=NNNN my=NNNN
; ============================================================================
print_status_line:
    push rax
    push rcx
    push rdx
    push rdi
    push rsi

    ; hits per slot
    lea rsi, [s_line_hit]
    call ucs_print
    mov edi, [v_hits + 0*4]
    call ucs_print_uint
    lea rsi, [s_space]
    call ucs_print
    mov edi, [v_hits + 1*4]
    call ucs_print_uint
    lea rsi, [s_space]
    call ucs_print
    mov edi, [v_hits + 2*4]
    call ucs_print_uint
    lea rsi, [s_space]
    call ucs_print
    mov edi, [v_hits + 3*4]
    call ucs_print_uint
    lea rsi, [s_space]
    call ucs_print
    mov edi, [v_hits + 4*4]
    call ucs_print_uint

    lea rsi, [s_arrow]
    call ucs_print
    mov edi, [v_mx]
    call ucs_print_uint
    lea rsi, [s_comma]
    call ucs_print
    mov edi, [v_my]
    call ucs_print_uint
    lea rsi, [s_space]
    call ucs_print
    mov rdi, [v_lastret + 4*8]                ; show USB transfer rc for triage
    call ucs_print_hex64
    call ucs_newline

    pop rsi
    pop rdi
    pop rdx
    pop rcx
    pop rax
    ret

; ============================================================================
; DATA
; ============================================================================
section .data
align 8
v_handle:           dq 0
v_systab:           dq 0
v_bs:               dq 0
v_conout:           dq 0
v_gop:              dq 0
v_fb:               dq 0
v_scrw:             dd 0
v_scrh:             dd 0
v_pitch_pixels:     dd 0
v_pixfmt:           dd 0
align 8
v_fbsize:           dq 0
g_trace_stall_us:   dd 130000                 ; 130 ms per trace step
v_enable_sppapp:    db 0                      ; 0 = SPP/APP polling OFF (they hang)
align 8
v_mx:               dd 400
v_my:               dd 300
v_prev_mx:          dd 400
v_prev_my:          dd 300

; Two slots per protocol: [0]=LocateProtocol, [1]=handle-enum
v_spp:              dq 0, 0
v_spp_ok:           db 0, 0
v_app:              dq 0, 0
v_app_ok:           db 0, 0
align 8
v_usb_io:           dq 0                      ; slot 4: USB IO Protocol iface
v_usb_ok:           db 0
v_usb_ep:           db 0                      ; IN endpoint address (with 0x80 bit)
v_usb_interval:     db 0
v_usb_iface_num:    db 0
v_usb_epattr:       db 0
v_usb_numep:        db 0
align 2
v_usb_maxpkt:       dw 0
align 8
v_usb_async_ret:    dq 0
usb_async_buf:      times 16 db 0
usb_async_report:   dd 0
usb_async_hits:     dd 0
v_async_seen:       dd 0
v_usb_found:        dd 0
v_usb_disc_ret:     dq 0
v_state:            db 0, 0, 0, 0, 0
align 8
v_lastret:          dq 0, 0, 0, 0, 0          ; last GetState/transfer return per slot
v_hits:             dd 0, 0, 0, 0, 0          ; success count per slot
v_frame:            dd 0

; USB descriptors + scratch
align 8
usb_if_desc:        times 16 db 0             ; EFI_USB_INTERFACE_DESCRIPTOR (9 bytes)
usb_ep_desc:        times 16 db 0             ; EFI_USB_ENDPOINT_DESCRIPTOR  (7 bytes)
usb_report_buf:     times 16 db 0             ; HID boot mouse report
usb_xfer_status:    dd 0
usb_setup_pkt:      times 8 db 0              ; EFI_USB_DEVICE_REQUEST
v_last_report:      dd 0                      ; last *nonzero* 4 bytes of report
drb_tmp:            dd 0                      ; scratch for draw_report_bars

; Scratch buffers for number formatting
align 8
num_scratch:        times 32 db 0             ; ASCII reverse digits
num_buf:            times 64 dw 0             ; UCS-2 output

; ConOut strings (UCS-2)
align 2
s_banner:       ustr "NexusOS UEFI Mouse Probe ZULU -- stays in UEFI, no kernel"
s_crlf:         ustr ""        ; OutputString interprets \r\n via CR/LF chars: use explicit
s_gop_res:      ustr "GOP: "
s_x:            ustr " x "
s_pitch:        ustr "  pitch="
s_fb:           ustr "  fb=0x"
s_pixfmt:       ustr "PixelFormat="
s_fbsize:       ustr "  fbsize=0x"
s_probing_spp:  ustr "Probing EFI_SIMPLE_POINTER_PROTOCOL ..."
s_probing_app:  ustr "Probing EFI_ABSOLUTE_POINTER_PROTOCOL ..."
s_main_hdr:     ustr "--- Live status: ret codes per slot, hit counts, cursor pos. WIGGLE INPUT ---"
s_line_ret:     ustr "ret  0=0x"
s_line_hit:     ustr "hits 0="
s_line_pos:     ustr "mx,my="
s_space:        ustr "  "
s_comma:        ustr ","
s_pad:          ustr "                    "   ; trailing spaces to clear stale digits
s_r_spp_loc_ok:    ustr "  [OK] SPP LocateProtocol  iface=0x"
s_r_spp_loc_fail:  ustr "  [..] SPP LocateProtocol  status=0x"
s_r_spp_enum_n:    ustr "  [..] SPP handles found="
s_r_spp_enum_ok:   ustr "  [OK] SPP via OpenProtocol iface=0x"
s_r_spp_enum_fail: ustr "  [..] SPP enum: no usable handle"
s_r_app_loc_ok:    ustr "  [OK] AbsolutePointer LocateProtocol iface=0x"
s_r_app_loc_fail:  ustr "  [..] AbsolutePointer LocateProtocol status=0x"
s_r_app_enum_n:    ustr "  [..] AbsolutePointer handles found="
s_r_app_enum_ok:   ustr "  [OK] AbsolutePointer via OpenProtocol iface=0x"
s_r_app_enum_fail: ustr "  [..] AbsolutePointer enum: no usable handle"
s_probing_usb:     ustr "Probing EFI_USB_IO_PROTOCOL ..."
s_r_usb_n:         ustr "  [..] USB_IO handles found="
s_r_usb_ok:        ustr "  [OK] USB HID mouse: ep=0x"
s_r_usb_fail:      ustr "  [..] USB_IO: no HID mouse found"
s_r_usb_setproto:  ustr "  [..] USB SET_PROTOCOL boot status=0x"
s_r_usb_async:     ustr "  [..] USB AsyncInterruptTransfer rc=0x"
s_d_iface:         ustr "  desc: iface="
s_d_ep:            ustr " ep="
s_d_attr:          ustr " attr="
s_d_mps:           ustr " maxpkt="
s_d_ivl:           ustr " ivl="
s_r_usb_disc:      ustr "  [..] DisconnectController rc=0x"
s_readpause:       ustr ">>> PAUSING 20s - photograph the desc:/rc lines above. Then WIGGLE MOUSE <<<"
s_live_label:      ustr "spp_loc spp_enum app_loc app_enum usb  mx,my"
s_arrow:           ustr " -> "

; Override s_crlf with actual CR LF chars (the macro above can't emit \r\n
; for a non-printable code, so we patch with raw words)
align 2
s_crlf_real:
    dw 13, 10, 0

; --- GUIDs ---
align 8
guid_gop:
    dd EFI_GOP_GUID_D1
    dw 0x23dc, 0x4a38
    db 0x96, 0xfb, 0x7a, 0xde, 0xd0, 0x80, 0x51, 0x6a

; EFI_SIMPLE_POINTER_PROTOCOL_GUID
; 31878c87-0b75-11d5-9a4f-0090273fc14d
guid_spp:
    dd EFI_SPP_GUID_D1
    dw 0x0b75, 0x11d5
    db 0x9a, 0x4f, 0x00, 0x90, 0x27, 0x3f, 0xc1, 0x4d

; EFI_ABSOLUTE_POINTER_PROTOCOL_GUID
; 8D59D32B-C655-4AE9-9B15-F25904992A43
guid_app:
    dd EFI_APP_GUID_D1
    dw 0xc655, 0x4ae9
    db 0x9b, 0x15, 0xf2, 0x59, 0x04, 0x99, 0x2a, 0x43

; EFI_USB_IO_PROTOCOL_GUID
; 2B2F68D6-0CD2-44CF-8E8B-BBA20B1B5B75
guid_usbio:
    dd EFI_USBIO_GUID_D1
    dw 0x0cd2, 0x44cf
    db 0x8e, 0x8b, 0xbb, 0xa2, 0x0b, 0x1b, 0x5b, 0x75

times (HDR_SZ + TEXT_RAW - ($ - $$)) db 0

; .reloc
    dd 0x1000, 12
    dw 0, 0

times (HDR_SZ + TEXT_RAW + RELOC_FSZ - ($ - $$)) db 0
