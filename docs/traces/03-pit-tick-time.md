# Trace 03 - PIT Tick → tick_count + Wall Clock

## Entry

IRQ0 (vector 32) at PIT_FREQUENCY (default 100 Hz, period 10 ms).

## Step-by-step

| # | File:Line | Action | State |
|---|---|---|---|
| 1 | `kernel/core/isr.asm:229-235` | `.irq_timer: call pit_handler / call apic_eoi / call pic_eoi_master` | LAPIC@0xB0 + PIC@0x20 |
| 2 | `kernel/core/pit.asm:25-29` | pit_handler push rax+rdx; `inc qword [tick_count]` | tick_count++ |
| 3 | pit.asm:31-33 | `inc dword [sub_ticks]; cmp [sub_ticks], PIT_FREQUENCY; jl .done` | sub_ticks++ |
| 4 | pit.asm:35-38 | sub_ticks = 0; `inc time_seconds`; if <60 done | seconds++ |
| 5 | pit.asm:40-43 | seconds = 0; `inc time_minutes`; if <60 done | minutes++ |
| 6 | pit.asm:45-48 | minutes = 0; `inc time_hours`; if <24 done | hours++ |
| 7 | pit.asm:49 | hours = 0 (rolls over at midnight) | hours=0 |

Returns. EOI handled by caller stub (NOT by pit_handler itself - verified Round 4).

## Consumers

- `tick_count` (qword, 100 Hz) - used as monotonic deadline in:
  - `xhci_submit_cmd`, `usb_wait_completion`, `xhci_find_port` `.wait_reset`/`.post_reset_wait`/`.wait_ped` (Round 5)
  - `ata_wait_ready`, `ata_wait_drq` (Round 9)
  - `spi_hid_init` reset wait (Round 9)
  - `keyboard_repeat_tick` deadline check
  - FPS computation in main.asm `.rf_fps`
- `time_hours, time_minutes` - taskbar clock render (`tb_draw` clock section).

## PIT init

`kernel/core/pit.asm:9-22`:
```
mov al, 0x36; out 0x43, al           ; mode 3, lobyte/hibyte
mov ax, PIT_DIVISOR (1193182/100=11932); out 0x40 lo; mov al,ah; out 0x40 hi
mov qword [tick_count], 0
mov dword [sub_ticks], 0
time_seconds=0, time_minutes=0, time_hours=12
```

## Audit-pass note

- Sub-agent Round 4 flagged "pit_handler missing EOI". Verified false: EOI is in the dispatcher (isr.asm:230-234), not in the handler. This is the right design - handlers are pure subroutines.
- `tick_count` is qword: at 100 Hz, wraps after 5.8 billion years. No wraparound concern.

## Failure modes

- Lost tick: if PIC EOI delayed too long, IRQ0 may queue and burst. Kernel handles gracefully - it's just a counter.
- Sub-ticks counter race: pit_handler is interrupt context, no other writer. Consumer reads `tick_count` are 8-byte aligned and atomic on x86.

## Invariants

- 0 ≤ sub_ticks < PIT_FREQUENCY
- 0 ≤ time_seconds < 60
- 0 ≤ time_minutes < 60
- 0 ≤ time_hours < 24
- tick_count monotonically increasing
