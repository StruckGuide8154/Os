; ---------------------------------------------------------------------------
; §1  Magic & layout constants
; ---------------------------------------------------------------------------
NIC1_MAGIC      equ 0x3143494E              ; 'NIC1'
NBA1_MAGIC      equ 0x3141424E              ; 'NBA1'
BMP_MAGIC16     equ 0x4D42                  ; 'BM'
XML_MAGIC16     equ 0x3F3C                  ; '<?'  catches <?xml ...?>
SVG_MAGIC32     equ 0x67767321              ; '<svg' little-endian probe

; Control bar layout. Kept in lockstep with media.nxh — change one, change
; the other. Both files use these names so hit-test (nxh) and drawing
; (here) cannot drift apart.
MEDIA_BAR_H         equ 26
MEDIA_BTN_W         equ 28
MEDIA_BTN_PLAY_X    equ 0
MEDIA_BTN_BACK_X    equ 28
MEDIA_BTN_FWD_X     equ 56
MEDIA_SCRUB_X       equ 88
MEDIA_TIME_W        equ 56

; Palette — centralised so a theme change touches one block.
MEDIA_COL_BAR_BG    equ 0x00131620
MEDIA_COL_BTN_BG    equ 0x002A6FFF
MEDIA_COL_TRACK_BG  equ 0x004B5563
MEDIA_COL_TRACK_FG  equ 0x002A6FFF
MEDIA_COL_KNOB      equ 0x00FFFFFF
MEDIA_COL_GLYPH     equ 0x00FFFFFF
MEDIA_COL_LETTERBOX equ 0x00000000
MEDIA_COL_TEXT_FG   equ 0x00FFFFFF
MEDIA_COL_TEXT_BG   equ 0x00131620

; Media-only BMP decode scratch. These offsets overlap Paint's per-window
; buffers, which is fine because every app window owns a private 2 MiB slot.
MEDIA_BMP_SCRATCH_OFF equ APP_SLOT_PAINT_CANVAS_OFF
MEDIA_BMP_SCRATCH_SZ  equ 0x43000
; Scaler / pixel constants. Values copied verbatim from the original inline
; literals further down this file.
MEDIA_FIXED_ONE   equ 0x10000     ; 16.16 fixed-point 1.0 (unity step = no horizontal/vertical scale)
MEDIA_ALPHA_MASK  equ 0xFF000000  ; ARGB alpha byte: test for keyed transparency / force opaque

; SVG placeholder gradient fill colors (ARGB), used by the vector fallback.
MEDIA_SVG_BG        equ 0x00050508  ; SVG placeholder backdrop (near-black)
MEDIA_SVG_GLOW      equ 0x00102A4A  ; central glow rectangle (dark blue)
MEDIA_SVG_RIBBON    equ 0x0000D7E8  ; cyan lower-left ribbon
MEDIA_SVG_FOLD      equ 0x00FF0844  ; magenta upper-left fold
MEDIA_SVG_FLOW      equ 0x00667EEA  ; violet upper-right flow
MEDIA_SVG_TWIST     equ 0x004F46E5  ; deep lower-right twist
; Per-window full-clip buffers. NBA videos can be far larger than a slot's
; 256 KiB media buffer, so each media window allocates its own physically
; contiguous buffer (page_alloc_contig, identity-mapped so the phys address
; doubles as a CPU pointer) sized to the file. Indexed by window id; ptr 0 =
; none, in which case the renderer falls back to the slot buffer. `pages` is
; the run length kept for page_free_contig on window close.
; (MEDIA_FULL_BUF_MAX_SZ lives in constants.inc — used by the loader.)
extern page_alloc_contig
extern page_free_contig
extern fat16_get_file_size

global media_full_buf
media_full_buf:        times MAX_WINDOWS dq 0
global media_full_buf_pages
media_full_buf_pages:  times MAX_WINDOWS dq 0
global media_direct_present
global media_direct_presented
media_direct_present db 0
media_direct_presented db 0

global app_media_draw
; nx_media_blit_scaled is reachable from the kernel via SYS_MEDIA_BLIT_SCALED
; (see syscall.asm → .sc_media_blit_scaled). Caller-side validation runs in
; the syscall stub; this routine itself trusts its register inputs.
global nx_media_blit_scaled


; ---------------------------------------------------------------------------
; §2  Codec dispatch — app_media_draw
;
; RDI = window struct ptr (kernel address).
; Probes the 32-bit magic at the start of the slot's media buffer and
; tail-calls the matching codec blitter. Unknown magic → blank frame so
; the window stays usable while the user tries another file.
;
; The dispatch ladder is intentionally cmp/je (not a pointer table)
; because the user-blob is COPIED into per-window slots at run time and
; runs at a different virtual address than where it was linked; any
; absolute function pointer baked into a `dq` row would still point at
; the kernel-image copy. Direct relative `call` instructions stay correct
; under that relocation.
; ---------------------------------------------------------------------------
app_media_draw:
    push rbx
    push r12
    push r13

    mov r13, rdi
    mov edi, [r13 + WIN_OFF_ID]
    call l3_slot_base
    lea r12, [rax + APP_SLOT_BMP_FILE_OFF]   ; file buffer

    ; SMAP: app_media_draw runs in KERNEL context (registered as a window draw
    ; fn — see header) yet reads the slot's media buffer (user, PTE.U=1) every
    ; frame and the blitters below stream slot pixels in tight loops. Arm AC for
    ; the whole body; the blitters / advance_frame it calls never touch AC, so
    ; it propagates, and they also write the kernel back buffer (fine with AC).
    USER_ACCESS_BEGIN

    mov eax, [r12]
    cmp eax, NIC1_MAGIC
    je .blit_nic
    cmp eax, NBA1_MAGIC
    je .blit_nba
    cmp eax, SVG_MAGIC32                     ; '<svg' bare-element form
    je .blit_svg

    ; 16-bit magics probed last so a stray high-word match in a 32-bit
    ; magic cannot mis-route.
    cmp word [r12], BMP_MAGIC16
    je .blit_bmp
    cmp word [r12], XML_MAGIC16
    je .blit_xml

    jmp .draw_done

.blit_nic:
    mov rdi, r12
    mov rsi, r13
    call nx_media_blit_nic
    jmp .draw_done
.blit_nba:
    mov rdi, r12                             ; default source = slot file buffer
    mov r8d, APP_SLOT_BMP_FILE_SZ            ; default capacity (bytes)
    mov eax, [r13 + WIN_OFF_ID]
    cmp eax, MAX_WINDOWS
    jae .blit_nba_go
    lea r9, [rel media_full_buf]
    mov r10, [r9 + rax*8]                    ; this window's full-clip buffer
    test r10, r10
    jz .blit_nba_go
    cmp dword [r10], NBA1_MAGIC              ; still a live NBA buffer?
    jne .blit_nba_go
    mov rdi, r10                             ; play from the full buffer
    lea r9, [rel media_full_buf_pages]
    mov r8, [r9 + rax*8]
    shl r8, 12                               ; pages -> capacity in bytes
.blit_nba_go:
    mov rsi, r13
    call nx_media_blit_nba                   ; rdi=src, rsi=window, r8=src capacity
    jmp .draw_done
.blit_bmp:
    mov rdi, r12
    mov rsi, r13
    call nx_media_blit_bmp
    jmp .draw_done
.blit_xml:
    mov rdi, r12
    mov rsi, r13
    call nx_media_blit_xml
    jmp .draw_done
.blit_svg:
    mov rdi, r12
    mov rsi, r13
    call nx_media_blit_svg

.draw_done:
    USER_ACCESS_END
    pop r13
    pop r12
    pop rbx
    ret


; media_release_window_buf(edi = window id)
;   Frees this window's per-window full-clip buffer (if any) and clears its
;   ownership slots. Called from the close path (wm_close_window) and before a
;   media window reuses its slot for a new clip. Safe to call when no buffer is
;   owned. Preserves all integer registers so it can drop into existing call
;   sequences without disturbing their state.
global media_release_window_buf
media_release_window_buf:
    push rbx
    push rcx
    push rdx
    push rsi
    push rdi
    mov ebx, edi
    cmp ebx, MAX_WINDOWS
    jae .mrwb_ret
    lea rdx, [rel media_full_buf]
    mov rdi, [rdx + rbx*8]                   ; buffer base (0 = none)
    test rdi, rdi
    jz .mrwb_ret
    lea rcx, [rel media_full_buf_pages]
    mov rsi, [rcx + rbx*8]                   ; page count
    mov qword [rdx + rbx*8], 0               ; clear ownership before freeing
    mov qword [rcx + rbx*8], 0
    call page_free_contig                    ; (rdi = base, rsi = pages)
.mrwb_ret:
    pop rdi
    pop rsi
    pop rdx
    pop rcx
    pop rbx
    ret


; ---------------------------------------------------------------------------
