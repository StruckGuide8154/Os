; ============================================================================
; Owner: src/boot/boot.asm legacy standalone UEFI image
; Section: Legacy UEFI strings and runtime state
; Included by boot.asm in boot order; keep binary-emitting statements ordered.
; ============================================================================

; ============================================================================
; STRING DATA
; ============================================================================
align 2
s_crlf: dw 13,10,0
s_sp: dw ' ',0
s_dash: dw '-',0
s_colon: dw ':',0
s_bksp: dw 8,' ',8,0
s_x: dw 'x',0

s_prompt: u {'nexus> '}
s_notxt: u {'[GOP not found - text mode]'}
         dw 13,10,0

; Commands
c_help: u {'help'}
c_clear: u {'clear'}
c_cls: u {'cls'}
c_ver: u {'ver'}
c_about: u {'about'}
c_reboot: u {'reboot'}
c_shutdown: u {'shutdown'}
c_time: u {'time'}
c_sysinfo: u {'sysinfo'}
c_desktop: u {'desktop'}
c_echo_p: u {'echo '}

s_unk: u {'Unknown command. Type "help".'}
       dw 13,10,0

s_hh: dw 13,10
      u {'  === NexusOS Commands ==='}
      dw 13,10,0
s_h1: u {'  help      - This help screen'}
      dw 13,10,0
s_h2: u {'  clear/cls - Clear screen'}
      dw 13,10,0
s_h3: u {'  echo <t>  - Print text'}
      dw 13,10,0
s_h4: u {'  sysinfo   - System info'}
      dw 13,10,0
s_h5: u {'  time      - Date and time'}
      dw 13,10,0
s_h6: u {'  ver       - Version'}
      dw 13,10,0
s_h7: u {'  about     - About NexusOS'}
      dw 13,10,0
s_h8: u {'  desktop   - Show graphical desktop'}
      dw 13,10,0
s_h9: u {'  reboot    - Reboot'}
      dw 13,10,0
s_h10: u {'  shutdown  - Power off'}
       dw 13,10,0
s_h11: dw 13,10,0

s_verfull: u {'NexusOS v2.0 [x86-64 UEFI] - Graphical Assembly OS'}
           dw 13,10,0

s_si1: dw 13,10
       u {'  -- System Information --'}
       dw 13,10,13,10,0
s_si2: u {'  Firmware: '}
s_si3: u {'  Arch:     x86-64 (AMD64) Long Mode'}
       dw 13,10,0
s_si4: u {'  Boot:     UEFI'}
       dw 13,10,0
s_si5: u {'  Display:  '}

s_ab1: dw 13,10
       u {'  -- About NexusOS --'}
       dw 13,10,13,10,0
s_ab2: u {'  Written from absolute zero in x86-64 assembly.'}
       dw 13,10,0
s_ab3: u {'  No C. No Rust. No libraries. Pure divine intelligence.'}
       dw 13,10,0
s_ab4: u {'  Now with GOP graphical desktop UI.'}
       dw 13,10,13,10,0

; ASCII strings for graphics rendering
a_title: db 'NexusOS v2.0',0
a_wintitle: db 'System Console',0
a_clock: db '00:00',0
a_startbtn: db 'NexusOS',0
a_closebtn: db 'x',0
a_minbtn: db '_',0
a_status: db 'UEFI x86-64 | GOP',0
a_mok: db 'Mouse:OK',0
a_mno: db 'Mouse:--',0

a_ln1: db '=== Welcome to NexusOS ===',0
a_ln2: db 'A complete operating system written from scratch.',0
a_ln3: db 'Every byte hand-crafted in x86-64 assembly.',0
a_ln4: db 'No C compiler. No Rust. No libraries.',0
a_ln5: db '--- System ---',0
a_ln6: db 'Architecture: x86-64 (AMD64) Long Mode',0
a_ln7: db 'Boot Mode:    UEFI 2.x',0
a_ln8: db 'Display:      GOP Framebuffer',0
a_ln9: db '--- Shell ---',0
a_ln10: db 'Type commands in the UEFI text console below.',0
a_ln11: db 'Use "help" to see available commands.',0

; ============================================================================
; VARIABLES
; ============================================================================
align 8
v_handle:  dq 0
v_systab:  dq 0
v_conout:  dq 0
v_conin:   dq 0
v_bs:      dq 0
v_rs:      dq 0
v_fwv:     dq 0
v_gop:     dq 0
v_gopmode: dq 0
v_fb:      dq 0
v_scrw:    dd 0
v_scrh:    dd 0
v_pitch:   dd 0
v_winw:    dd 0
v_winh:    dd 0
v_tmp32:   dd 0
v_bltpx:   dd 0
v_mouse:   dq 0         ; Simple Pointer Protocol pointer
v_mx:      dd 0         ; mouse cursor X
v_my:      dd 0         ; mouse cursor Y
v_mvis:    db 0         ; cursor visible flag
v_mclick:  db 0         ; left button state
v_mfound:  db 0         ; 0=found, 1=not found
v_mtype:   db 0         ; 0=simple pointer (relative), 1=absolute pointer
v_mx_drn:  dd 0         ; cursor X when last drawn
v_my_drn:  dd 0         ; cursor Y when last drawn

align 16
char_buf:    times 64 dd 0    ; 8x8 pixel buffer for character rendering (256 bytes)
cursor_save: times 320 dd 0   ; 16x20 saved background (1280 bytes)
cursor_buf:  times 320 dd 0   ; 16x20 rendered cursor (1280 bytes)

kd:      times 4 db 0
eb:      times 4 db 0
dbuf:    times 24 db 0
d2buf:   times 8 db 0
cmd_buf: times 520 db 0
