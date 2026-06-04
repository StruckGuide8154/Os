; ============================================================================
; Owner: src/boot/boot.asm legacy standalone UEFI image
; Section: Legacy UEFI shell and command handlers
; Included by boot.asm in boot order; keep binary-emitting statements ordered.
; ============================================================================

; ============================================================================
; TEXT-MODE SHELL (fallback + interactive)
; ============================================================================
fn_shell:
    push rbx
    push rsi
    sub rsp, 40
.loop:
    ; If in graphics mode, draw shell in the window area
    ; For now use text mode shell
    mov dl, LCYAN
    call fn_tcolor
    lea rcx, [s_prompt]
    call fn_tpr
    mov dl, WHITE
    call fn_tcolor
    lea rcx, [cmd_buf]
    mov edx, 250
    call fn_rdln
    lea rcx, [cmd_buf]
    call fn_exec
    jmp .loop
    add rsp, 40
    pop rsi
    pop rbx
    ret

fn_exec:
    push rbx
    push rsi
    sub rsp, 40
    mov rsi, rcx
.sk: movzx eax, word [rsi]
    cmp ax,' '
    jne .ck
    add rsi,2
    jmp .sk
.ck: cmp ax,0
    je .done

    lea rdx,[c_help]
    mov rcx,rsi
    call fn_scmp
    test eax,eax
    jz .help

    lea rdx,[c_clear]
    mov rcx,rsi
    call fn_scmp
    test eax,eax
    jz .clear

    lea rdx,[c_cls]
    mov rcx,rsi
    call fn_scmp
    test eax,eax
    jz .clear

    lea rdx,[c_time]
    mov rcx,rsi
    call fn_scmp
    test eax,eax
    jz .time

    lea rdx,[c_sysinfo]
    mov rcx,rsi
    call fn_scmp
    test eax,eax
    jz .sysi

    lea rdx,[c_about]
    mov rcx,rsi
    call fn_scmp
    test eax,eax
    jz .about

    lea rdx,[c_reboot]
    mov rcx,rsi
    call fn_scmp
    test eax,eax
    jz .reboot

    lea rdx,[c_shutdown]
    mov rcx,rsi
    call fn_scmp
    test eax,eax
    jz .shut

    lea rdx,[c_desktop]
    mov rcx,rsi
    call fn_scmp
    test eax,eax
    jz .desk

    lea rdx,[c_echo_p]
    mov rcx,rsi
    call fn_pfx
    test eax,eax
    jz .echo

    lea rdx,[c_ver]
    mov rcx,rsi
    call fn_scmp
    test eax,eax
    jz .ver

    mov dl, LRED
    call fn_tcolor
    lea rcx,[s_unk]
    call fn_tpr
    mov dl, WHITE
    call fn_tcolor
    jmp .done

.help: call fn_c_help
    jmp .done
.clear: call fn_cls
    jmp .done
.time: call fn_c_time
    jmp .done
.sysi: call fn_c_sysi
    jmp .done
.about: call fn_c_about
    jmp .done
.reboot:
    mov rcx,[v_rs]
    mov rax,[rcx+RS_RESET]
    mov ecx,1
    xor edx,edx
    xor r8d,r8d
    xor r9d,r9d
    sub rsp,32
    call rax
    add rsp,32
    jmp .done
.shut:
    mov rcx,[v_rs]
    mov rax,[rcx+RS_RESET]
    mov ecx,2
    xor edx,edx
    xor r8d,r8d
    xor r9d,r9d
    sub rsp,32
    call rax
    add rsp,32
    jmp .done
.desk:
    cmp qword [v_gop], 0
    je .done
    call fn_desktop
    call fn_cursor_show
    ; Stay in graphics mode - interactive loop with mouse
.desk_wait:
    ; Poll keyboard
    mov rcx, [v_conin]
    mov rax, [rcx + CI_KEY]
    lea rdx, [kd]
    call rax
    test rax, rax
    jnz .desk_poll_mouse
    ; Got key - check if ESC (scan code 0x17)
    movzx eax, word [kd]
    cmp ax, 0x17
    je .desk_exit
    ; Check if it's a mouse key (arrows, *, -)
    call fn_kb_mouse
    test eax, eax
    jnz .desk_kb_moved
    ; Other key - ignore on desktop
    jmp .desk_wait
.desk_kb_moved:
    cmp eax, 2             ; left click?
    je .desk_kb_click
    call fn_cursor_hide
    call fn_cursor_show
    jmp .desk_wait
.desk_kb_click:
    call fn_handle_click
    cmp eax, 1             ; close
    je .desk_exit
    cmp eax, 3             ; start -> shell
    je .desk_exit
    jmp .desk_wait
.desk_poll_mouse:
    ; Poll hardware mouse
    call fn_mouse_poll
    cmp eax, 0
    je .desk_stall
    cmp eax, 2
    je .desk_hw_click
    ; Mouse moved - update cursor
    call fn_cursor_hide
    call fn_cursor_show
    jmp .desk_wait
.desk_hw_click:
    call fn_handle_click
    cmp eax, 1
    je .desk_exit
    cmp eax, 3
    je .desk_exit
    call fn_cursor_hide
    call fn_cursor_show
    jmp .desk_wait
.desk_stall:
    mov rcx, 5000
    call fn_stall
    jmp .desk_wait
.desk_exit:
    call fn_cursor_hide
    call fn_cls
    jmp .done
.echo:
    add rsi,10
    mov rcx,rsi
    call fn_tpr
    lea rcx,[s_crlf]
    call fn_tpr
    jmp .done
.ver:
    mov dl, LCYAN
    call fn_tcolor
    lea rcx,[s_verfull]
    call fn_tpr
    mov dl, WHITE
    call fn_tcolor
    jmp .done
.done:
    add rsp,40
    pop rsi
    pop rbx
    ret

; COMMANDS
fn_c_help:
    sub rsp,40
    mov dl,YELLOW
    call fn_tcolor
    lea rcx,[s_hh]
    call fn_tpr
    mov dl,LGRAY
    call fn_tcolor
    %assign hn 1
    %rep 11
    lea rcx,[s_h %+ hn]
    call fn_tpr
    %assign hn hn+1
    %endrep
    mov dl,WHITE
    call fn_tcolor
    add rsp,40
    ret

fn_c_time:
    sub rsp,64
    mov rcx,[v_rs]
    mov rax,[rcx+RS_TIME]
    lea rcx,[rsp+32]
    xor edx,edx
    call rax
    mov dl,LGREEN
    call fn_tcolor
    movzx eax,word [rsp+32]
    call fn_pdec
    lea rcx,[s_dash]
    call fn_tpr
    movzx eax,byte [rsp+34]
    call fn_pdec2
    lea rcx,[s_dash]
    call fn_tpr
    movzx eax,byte [rsp+35]
    call fn_pdec2
    lea rcx,[s_sp]
    call fn_tpr
    movzx eax,byte [rsp+36]
    call fn_pdec2
    lea rcx,[s_colon]
    call fn_tpr
    movzx eax,byte [rsp+37]
    call fn_pdec2
    lea rcx,[s_colon]
    call fn_tpr
    movzx eax,byte [rsp+38]
    call fn_pdec2
    lea rcx,[s_crlf]
    call fn_tpr
    mov dl,WHITE
    call fn_tcolor
    add rsp,64
    ret

fn_c_sysi:
    sub rsp,40
    mov dl,YELLOW
    call fn_tcolor
    lea rcx,[s_si1]
    call fn_tpr
    mov dl,LGRAY
    call fn_tcolor
    lea rcx,[s_si2]
    call fn_tpr
    mov dl,WHITE
    call fn_tcolor
    mov rcx,[v_fwv]
    call fn_tpr
    lea rcx,[s_crlf]
    call fn_tpr
    mov dl,LGRAY
    call fn_tcolor
    lea rcx,[s_si3]
    call fn_tpr
    lea rcx,[s_si4]
    call fn_tpr

    ; Show GOP resolution if available
    cmp qword [v_gop], 0
    je .nores
    lea rcx,[s_si5]
    call fn_tpr
    mov eax, [v_scrw]
    call fn_pdec
    lea rcx, [s_x]
    call fn_tpr
    mov eax, [v_scrh]
    call fn_pdec
    lea rcx,[s_crlf]
    call fn_tpr
.nores:
    mov dl,WHITE
    call fn_tcolor
    add rsp,40
    ret

fn_c_about:
    sub rsp,40
    mov dl,LMAG
    call fn_tcolor
    lea rcx,[s_ab1]
    call fn_tpr
    mov dl,LGRAY
    call fn_tcolor
    lea rcx,[s_ab2]
    call fn_tpr
    lea rcx,[s_ab3]
    call fn_tpr
    lea rcx,[s_ab4]
    call fn_tpr
    mov dl,WHITE
    call fn_tcolor
    add rsp,40
    ret

; ============================================================================
; TEXT I/O PRIMITIVES
; ============================================================================
fn_tpr:
    push rbx
    sub rsp,32
    mov rbx,rcx
    mov rcx,[v_conout]
    mov rdx,rbx
    mov rax,[rcx+CO_STR]
    call rax
    add rsp,32
    pop rbx
    ret

fn_tcolor:
    sub rsp,40
    mov rcx,[v_conout]
    movzx edx,dl
    mov rax,[rcx+CO_ATTR]
    call rax
    add rsp,40
    ret

fn_cls:
    sub rsp,40
    mov rcx,[v_conout]
    mov rax,[rcx+CO_CLR]
    call rax
    add rsp,40
    ret

fn_stall:
    sub rsp,40
    mov rax,[v_bs]
    mov rax,[rax+BS_STALL]
    call rax
    add rsp,40
    ret

fn_rdln:
    push rbx
    push rsi
    push rdi
    push r12
    push r13
    sub rsp,48
    mov rdi,rcx
    mov r12d,edx
    xor r13d,r13d
.rl: mov rcx,[v_conin]
    mov rax,[rcx+CI_KEY]
    lea rdx,[kd]
    call rax
    test rax,rax
    jnz .rlw
    movzx ebx,word [kd+2]
    cmp bx,13
    je .rle
    cmp bx,8
    je .rlb
    cmp bx,0x20
    jb .rl
    cmp r13d,r12d
    jge .rl
    mov [rdi+r13*2],bx
    inc r13d
    mov word [eb],bx
    mov word [eb+2],0
    lea rcx,[eb]
    call fn_tpr
    jmp .rl
.rlw: mov rcx,10000
    call fn_stall
    jmp .rl
.rlb: cmp r13d,0
    je .rl
    dec r13d
    lea rcx,[s_bksp]
    call fn_tpr
    jmp .rl
.rle: mov word [rdi+r13*2],0
    lea rcx,[s_crlf]
    call fn_tpr
    add rsp,48
    pop r13
    pop r12
    pop rdi
    pop rsi
    pop rbx
    ret

fn_scmp:
    push rsi
    push rdi
    mov rsi,rcx
    mov rdi,rdx
.sc: movzx eax,word [rdi]
    movzx ecx,word [rsi]
    test ax,ax
    jz .sce
    cmp ax,'A'
    jb .s1
    cmp ax,'Z'
    ja .s1
    add ax,32
.s1: cmp cx,'A'
    jb .s2
    cmp cx,'Z'
    ja .s2
    add cx,32
.s2: cmp ax,cx
    jne .scn
    add rsi,2
    add rdi,2
    jmp .sc
.sce: cmp cx,0
    je .scy
    cmp cx,' '
    je .scy
.scn: mov eax,1
    pop rdi
    pop rsi
    ret
.scy: xor eax,eax
    pop rdi
    pop rsi
    ret

fn_pfx:
    push rsi
    push rdi
    mov rsi,rcx
    mov rdi,rdx
.pf: movzx eax,word [rdi]
    test ax,ax
    jz .pfy
    movzx ecx,word [rsi]
    cmp ax,'A'
    jb .p1
    cmp ax,'Z'
    ja .p1
    add ax,32
.p1: cmp cx,'A'
    jb .p2
    cmp cx,'Z'
    ja .p2
    add cx,32
.p2: cmp ax,cx
    jne .pfn
    add rsi,2
    add rdi,2
    jmp .pf
.pfy: xor eax,eax
    pop rdi
    pop rsi
    ret
.pfn: mov eax,1
    pop rdi
    pop rsi
    ret

fn_pdec:
    push rbx
    push rsi
    sub rsp,40
    lea rsi,[dbuf+20]
    mov word [rsi],0
    sub rsi,2
    mov ebx,10
    test eax,eax
    jnz .pd
    mov word [rsi],'0'
    mov rcx,rsi
    call fn_tpr
    jmp .pdd
.pd: test eax,eax
    jz .pdp
    xor edx,edx
    div ebx
    add dl,'0'
    mov byte [rsi],dl
    mov byte [rsi+1],0
    sub rsi,2
    jmp .pd
.pdp: add rsi,2
    mov rcx,rsi
    call fn_tpr
.pdd: add rsp,40
    pop rsi
    pop rbx
    ret

fn_pdec2:
    sub rsp,40
    mov ecx,10
    xor edx,edx
    div ecx
    add al,'0'
    add dl,'0'
    mov byte [d2buf],al
    mov byte [d2buf+1],0
    mov byte [d2buf+2],dl
    mov byte [d2buf+3],0
    mov word [d2buf+4],0
    lea rcx,[d2buf]
    call fn_tpr
    add rsp,40
    ret

