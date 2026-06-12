# Trace 01 - PS/2 Mouse Click → Cursor Move + Click Dispatch

## Entry

CPU receives IRQ12 (vector 44) from 8259 slave PIC.
Hardware state at entry: PS/2 controller has pushed a 3- or 4-byte mouse packet to port 0x60 buffer.

## Step-by-step

| # | File:Line | Code | State touched |
|---|---|---|---|
| 1 | `kernel/core/idt.asm` | IDT[44] → `irq_common_stub` (vec=44 in [rsp+8]) | RIP/CS/RFLAGS pushed by CPU; PUSH_ALL saves regs |
| 2 | `kernel/core/isr.asm:222` | `cmp rax, 44 / je .irq_mouse` | Vector dispatch |
| 3 | `kernel/core/isr.asm:243` | `.irq_mouse: call mouse_handler` | - |
| 4 | `kernel/drivers/mouse.asm` | mouse_handler reads port 0x60, advances `mouse_cycle` 0→1→2→(3 if IM) | `mouse_packet[0..3]`, `mouse_cycle` |
| 5 | mouse.asm `.process_packet` | bytes → dx/dy signed, buttons LSB | `mouse_x += dx`, `mouse_y -= dy`, `mouse_buttons`, `mouse_moved=1` |
| 6 | `kernel/core/isr.asm:244-247` | `call apic_eoi / call pic_eoi_slave / call pic_eoi_master` | LAPIC EOI@0xB0; 8259 EOIs to 0xA0 then 0x20 |
| 7 | isr.asm `.done` → `iretq` | POP_ALL + add rsp,16 | Stack restored |

(Round 1 fix: lines 244-247 added the dual PIC EOI; was previously missing → mouse stopped after 1 IRQ.)

## Main-loop pickup

| # | File:Line | Action |
|---|---|---|
| 8 | `kernel/core/main.asm:461` | `call mouse_check_moved` returns AL=1 if dirty |
| 9 | main.asm:465-467 | edi=mouse_x, esi=mouse_y, dl=mouse_buttons |
| 10 | main.asm:471 | `call wm_handle_mouse_event` - locates window under cursor |
| 11 | window.asm wm_handle | iterates `window_pool` slots with WF_ACTIVE; hit-test (X..X+W, Y..Y+H) |
| 12 | window.asm | if button & 0x01 and click handler set: `call [WIN_OFF_CLICKFN]` |
| 13 | callback (e.g. `app_explorer_click` explorer.inc:464) | runs in kernel context; returns |
| 14 | main.asm | sets `scene_dirty=1` |

## Cursor visual update

| # | File:Line | Action |
|---|---|---|
| 15 | main.asm render-loop | `call cursor_update(edi=x, esi=y)` |
| 16 | cursor.asm `cursor_update` | calls `cursor_hide` (restores old bg) then `cursor_draw(x,y)` |
| 17 | cursor.asm `cursor_draw` | saves CURSOR_WIDTH × CURSOR_HEIGHT region from `bb_addr` into `cursor_bg_save`; XORs cursor pixels into back-buffer |
| 18 | display.asm `display_flip_rect(x,y,w,h)` | rep movsd row-by-row from `bb_addr+y*pitch+x*4` to framebuffer |

(Round 4 fix at step 17: `cursor_draw` now `push r14`/`pop r14` around row-pointer use.)

## Failure modes guarded

- Missing PIC EOI → IRQ12 line stuck → no further mouse events. (Fixed.)
- PS/2 wait-loop hangs → 100k-iter timeout in mouse_wait_input/_output (MEMORY.md fix #3).
- `mouse_buttons` race: IRQ writes byte; main-loop reads byte. Single-byte access is atomic on x86, so no torn read.

## Invariants

- `mouse_packet` cycle index modulo 3 (or 4 in IM mode) MUST match `mouse_im_mode` at packet boundary.
- `mouse_x ∈ [0, scr_width)`, `mouse_y ∈ [0, scr_height)`. Clamped in mouse_handler.
