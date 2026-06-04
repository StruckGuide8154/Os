; ============================================================================
; Owner: src/boot/boot.asm legacy standalone UEFI image
; Section: Legacy UEFI desktop UI
; Included by boot.asm in boot order; keep binary-emitting statements ordered.
; ============================================================================

; ============================================================================
; DESKTOP UI
; ============================================================================
fn_desktop:
    sub rsp, 40

    ; Disable text cursor FIRST to prevent UEFI text layer from overwriting framebuffer
    mov rcx, [v_conout]
    xor edx, edx        ; FALSE = hide cursor
    mov rax, [rcx + 64]  ; EnableCursor offset
    sub rsp, 32
    call rax
    add rsp, 32

    ; ---- COLOR SCHEME (BGRX) ----
    ; Desktop bg:    0x00553311  (warm dark brown)
    ; Panel/bar:     0x00331A08  (deep brown)
    ; Panel accent:  0x00664422  (medium brown)
    ; Window bg:     0x00201018  (near-black with warm tint)
    ; Window title:  0x00883310  (rich amber)
    ; Highlight:     0x00CC6620  (bright amber)
    ; Text light:    0x00E0D0C0  (warm white)
    ; Text mid:      0x00A09888  (muted)

    ; === DESKTOP BACKGROUND ===
    mov edi, 0
    mov esi, 0
    mov edx, [v_scrw]
    mov ecx, [v_scrh]
    mov r8d, 0x00422210     ; warm dark brown
    call fn_fill_rect

    ; === TOP PANEL (30px) ===
    mov edi, 0
    mov esi, 0
    mov edx, [v_scrw]
    mov ecx, 30
    mov r8d, 0x00201008     ; deep dark panel
    call fn_fill_rect

    ; Panel bottom accent line (1px)
    mov edi, 0
    mov esi, 30
    mov edx, [v_scrw]
    mov ecx, 1
    mov r8d, 0x00553318     ; subtle border
    call fn_fill_rect

    ; Panel title
    mov edi, 12
    mov esi, 11
    lea rdx, [a_title]
    mov ecx, 0x00E8C878     ; warm gold
    mov r8d, 0x00201008
    call fn_draw_str

    ; Clock
    call fn_draw_clock

    ; === MAIN WINDOW ===
    mov eax, [v_scrw]
    sub eax, 80
    mov [v_winw], eax
    mov eax, [v_scrh]
    sub eax, 110
    mov [v_winh], eax

    ; Window drop shadow (offset +4,+4)
    mov edi, 44
    mov esi, 52
    mov edx, [v_winw]
    mov ecx, [v_winh]
    mov r8d, 0x00180A02     ; very dark shadow
    call fn_fill_rect

    ; Window outer border (1px bright edge)
    mov edi, 39
    mov esi, 47
    mov edx, [v_winw]
    add edx, 2
    mov ecx, [v_winh]
    add ecx, 2
    mov r8d, 0x00664422     ; border color
    call fn_fill_rect

    ; Window body
    mov edi, 40
    mov esi, 48
    mov edx, [v_winw]
    mov ecx, [v_winh]
    mov r8d, 0x00241410     ; dark window body
    call fn_fill_rect

    ; Window title bar (26px)
    mov edi, 40
    mov esi, 48
    mov edx, [v_winw]
    mov ecx, 26
    mov r8d, 0x00883310     ; rich amber title bar
    call fn_fill_rect

    ; Title bar bottom edge
    mov edi, 40
    mov esi, 74
    mov edx, [v_winw]
    mov ecx, 1
    mov r8d, 0x00AA5520     ; brighter amber accent
    call fn_fill_rect

    ; Close button (right side of title bar) - red square
    mov eax, [v_winw]
    add eax, 40
    sub eax, 24              ; right edge - 24px
    mov edi, eax
    mov esi, 52
    mov edx, 18
    mov ecx, 18
    mov r8d, 0x002020CC     ; red (BGRX: low B, low G, high R)
    call fn_fill_rect

    ; Close button "X" text
    mov eax, [v_winw]
    add eax, 40
    sub eax, 21
    mov edi, eax
    mov esi, 57
    lea rdx, [a_closebtn]
    mov ecx, 0x00FFFFFF
    mov r8d, 0x002020CC
    call fn_draw_str

    ; Minimize button (left of close)
    mov eax, [v_winw]
    add eax, 40
    sub eax, 48
    mov edi, eax
    mov esi, 52
    mov edx, 18
    mov ecx, 18
    mov r8d, 0x0020A0CC     ; amber/yellow
    call fn_fill_rect

    ; Minimize "_" text
    mov eax, [v_winw]
    add eax, 40
    sub eax, 45
    mov edi, eax
    mov esi, 57
    lea rdx, [a_minbtn]
    mov ecx, 0x00201008
    mov r8d, 0x0020A0CC
    call fn_draw_str

    ; Window title text
    mov edi, 52
    mov esi, 55
    lea rdx, [a_wintitle]
    mov ecx, 0x00FFFFFF
    mov r8d, 0x00883310
    call fn_draw_str

    ; === WINDOW CONTENT ===
    ; Content area starts at y=85

    mov edi, 60
    mov esi, 90
    lea rdx, [a_ln1]
    mov ecx, 0x0058D8F8     ; bright cyan-gold
    mov r8d, 0x00241410
    call fn_draw_str

    ; Separator line under heading
    mov edi, 60
    mov esi, 102
    mov edx, 220
    mov ecx, 1
    mov r8d, 0x00554030
    call fn_fill_rect

    mov edi, 60
    mov esi, 114
    lea rdx, [a_ln2]
    mov ecx, 0x00B0A898
    mov r8d, 0x00241410
    call fn_draw_str

    mov edi, 60
    mov esi, 130
    lea rdx, [a_ln3]
    mov ecx, 0x00B0A898
    mov r8d, 0x00241410
    call fn_draw_str

    mov edi, 60
    mov esi, 146
    lea rdx, [a_ln4]
    mov ecx, 0x00B0A898
    mov r8d, 0x00241410
    call fn_draw_str

    ; System section header
    mov edi, 60
    mov esi, 172
    lea rdx, [a_ln5]
    mov ecx, 0x0060E880     ; bright green
    mov r8d, 0x00241410
    call fn_draw_str

    ; Separator
    mov edi, 60
    mov esi, 184
    mov edx, 120
    mov ecx, 1
    mov r8d, 0x00405030
    call fn_fill_rect

    mov edi, 60
    mov esi, 196
    lea rdx, [a_ln6]
    mov ecx, 0x00B0A898
    mov r8d, 0x00241410
    call fn_draw_str

    mov edi, 60
    mov esi, 212
    lea rdx, [a_ln7]
    mov ecx, 0x00B0A898
    mov r8d, 0x00241410
    call fn_draw_str

    mov edi, 60
    mov esi, 228
    lea rdx, [a_ln8]
    mov ecx, 0x00B0A898
    mov r8d, 0x00241410
    call fn_draw_str

    ; Shell section header
    mov edi, 60
    mov esi, 254
    lea rdx, [a_ln9]
    mov ecx, 0x00FF80FF     ; magenta/pink
    mov r8d, 0x00241410
    call fn_draw_str

    ; Separator
    mov edi, 60
    mov esi, 266
    mov edx, 120
    mov ecx, 1
    mov r8d, 0x00504030
    call fn_fill_rect

    mov edi, 60
    mov esi, 278
    lea rdx, [a_ln10]
    mov ecx, 0x00B0A898
    mov r8d, 0x00241410
    call fn_draw_str

    mov edi, 60
    mov esi, 298
    lea rdx, [a_ln11]
    mov ecx, 0x0050D0FF     ; orange accent
    mov r8d, 0x00241410
    call fn_draw_str

    ; === BOTTOM TASKBAR (36px) ===
    mov edi, 0
    mov eax, [v_scrh]
    sub eax, 36
    mov esi, eax
    mov edx, [v_scrw]
    mov ecx, 36
    mov r8d, 0x00201008     ; deep dark - matches top panel
    call fn_fill_rect

    ; Taskbar top accent line
    mov edi, 0
    mov eax, [v_scrh]
    sub eax, 36
    mov esi, eax
    mov edx, [v_scrw]
    mov ecx, 1
    mov r8d, 0x00553318     ; subtle border (matches top)
    call fn_fill_rect

    ; Taskbar "start" button area
    mov edi, 4
    mov eax, [v_scrh]
    sub eax, 32
    mov esi, eax
    mov edx, 88
    mov ecx, 28
    mov r8d, 0x00663818     ; slightly lighter
    call fn_fill_rect

    ; Start button text
    mov edi, 12
    mov eax, [v_scrh]
    sub eax, 24
    mov esi, eax
    lea rdx, [a_startbtn]
    mov ecx, 0x00E8C878     ; gold like panel title
    mov r8d, 0x00663818
    call fn_draw_str

    ; Taskbar window tab
    mov edi, 100
    mov eax, [v_scrh]
    sub eax, 32
    mov esi, eax
    mov edx, 200
    mov ecx, 28
    mov r8d, 0x00442818     ; active tab bg
    call fn_fill_rect

    ; Tab active indicator (2px bright line at top)
    mov edi, 100
    mov eax, [v_scrh]
    sub eax, 32
    mov esi, eax
    mov edx, 200
    mov ecx, 2
    mov r8d, 0x00CC8840     ; amber indicator
    call fn_fill_rect

    ; Tab text
    mov edi, 108
    mov eax, [v_scrh]
    sub eax, 24
    mov esi, eax
    lea rdx, [a_wintitle]
    mov ecx, 0x00D0C0B0
    mov r8d, 0x00442818
    call fn_draw_str

    ; Status area (right side of taskbar)
    mov eax, [v_scrw]
    sub eax, 200
    mov edi, eax
    mov eax, [v_scrh]
    sub eax, 24
    mov esi, eax
    lea rdx, [a_status]
    mov ecx, 0x0060B080     ; green status
    mov r8d, 0x00201008
    call fn_draw_str

    add rsp, 40
    ret

; Draw clock on title bar
fn_draw_clock:
    sub rsp, 64
    mov rcx, [v_rs]
    mov rax, [rcx + RS_TIME]
    lea rcx, [rsp+32]
    xor edx, edx
    call rax

    ; Format HH:MM
    movzx eax, byte [rsp+36]   ; hour
    mov ecx, 10
    xor edx, edx
    div ecx
    add al, '0'
    add dl, '0'
    mov [a_clock], al
    mov [a_clock+1], dl
    movzx eax, byte [rsp+37]   ; minute
    xor edx, edx
    div ecx
    add al, '0'
    add dl, '0'
    mov [a_clock+3], al
    mov [a_clock+4], dl

    mov eax, [v_scrw]
    sub eax, 60
    mov edi, eax
    mov esi, 11
    lea rdx, [a_clock]
    mov ecx, 0x00E0D0C0       ; warm white
    mov r8d, 0x00201008        ; match panel bg
    call fn_draw_str
    add rsp, 64
    ret

