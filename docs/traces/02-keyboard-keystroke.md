# Trace 02 - PS/2 Keystroke → Key Buffer → App Consumer

## Entry

IRQ1 (vector 33) from 8259 master PIC. Scancode in port 0x60.

## Step-by-step

| # | File:Line | Code | State |
|---|---|---|---|
| 1 | `kernel/core/isr.asm:220-241` | dispatch IRQ1 → `keyboard_handler`; then `apic_eoi` + `pic_eoi_master` | EOIs |
| 2 | `kernel/drivers/keyboard.asm` `keyboard_handler` | `in al, 0x60` → scancode | - |
| 3 | keyboard.asm | extended (0xE0) prefix capture; modifier (Shift/Ctrl/Alt/Caps/NumLock) toggles → `kb_modifiers` byte | `kb_modifiers` |
| 4 | keyboard.asm | non-modifier scancode → lookup `scancode_normal[]` or `scancode_shifted[]` (0x00-0x58) → ASCII | - |
| 5 | keyboard.asm | press: write 4-byte event `{scancode, ascii, modifiers, flags}` to `kb_buffer[kb_tail]`; advance `kb_tail = (tail+1) & (KB_BUFFER_SIZE-1)` | ring buffer |
| 6 | keyboard.asm | start key-repeat: `kb_repeat_scancode/ascii = current`; `kb_repeat_next_tick = tick_count + KB_REPEAT_DELAY (40)` | repeat state |
| 7 | release (scancode | 0x80): clears `kb_repeat_scancode` if it was the held key |

## Repeat ticking

| # | File:Line | Action |
|---|---|---|
| 8 | main.asm per-frame | `call keyboard_repeat_tick` |
| 9 | keyboard.asm | if `kb_repeat_scancode != 0` and `tick_count >= kb_repeat_next_tick`: enqueue another event into kb_buffer; `next_tick += KB_REPEAT_RATE (5)` |

## Consumer drain

| # | File:Line | Action |
|---|---|---|
| 10 | main.asm | `.kb_drain_loop: call keyboard_available` (returns 1 if `head != tail`) |
| 11 | main.asm | `call keyboard_read` - reads 4 bytes at `kb_buffer[kb_head*4]`, advances `kb_head` |
| 12 | main.asm | dispatches to focused window's `WIN_OFF_KEYFN` callback |

## Audit-pass guarantees

- **Round 3 fix**: `keyboard_read` now `push rbx`/`pop rbx` around `lea rbx, [kb_buffer + r8]` use. Was a callee-save violation that could corrupt caller's rbx.
- **Round 1 fix**: `.irq_keyboard` in isr.asm now calls `pic_eoi_master` after `apic_eoi` - without it the 8259 line stays asserted on PIC-routed systems.

## Failure modes

- Buffer overflow: ring is power-of-2 size, `head==tail` means empty (one slot wasted). Producer overruns consumer if `tail+1==head` after enqueue - currently silently drops (no overrun check). 32-slot buffer is enough at human typing rates.
- USB keyboard: parallel path via `usb_parse_keyboard_report` (usb_hid.asm) writes the same `kb_buffer`; modifiers also feed `kb_modifiers`. PS/2 and USB events interleave correctly because both writers run on IRQ context with non-overlapping windows.

## Invariants

- `kb_head, kb_tail ∈ [0, KB_BUFFER_SIZE)`.
- `kb_modifiers` bits: KMOD_SHIFT=1, CTRL=2, ALT=4, CAPS=8, NUM=16.
- A press event always sets `kb_repeat_scancode`; a release of the same key always clears it.
