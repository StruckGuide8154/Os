# Trace 07 - I2C Touchpad Two-Finger Pinch → mouse_pinch_delta

## Entry

Per-frame call from main loop: `call i2c_hid_poll` (kernel/drivers/i2c_hid.asm).

## Step-by-step

### Phase 1: poll state machine

| # | File:Line | Action |
|---|---|---|
| 1 | i2c_hid.asm:867-868 | early return if `[i2c_hid_active] != 1` |
| 2 | i2c_hid.asm:869 | `push rbx` (Round 6 fix - was missing) |
| 3 | i2c_hid.asm:870 | `mov rsi, [i2c_base_addr]` - DW I2C MMIO base |
| 4 | i2c_hid.asm:872-880 | check TX abort via `DW_IC_RAW_INTR_STAT` bit 6; on abort drain via `DW_IC_CLR_TX_ABRT`, `inc i2c_error_count`, if ≥50 reset bus |
| 5 | i2c_hid.asm:884 | switch on `i2c_poll_state` (0/1/2) |

### Phase 2: state 0 - issue read

- Write `wInputRegister` (parsed from HID descriptor offset 8) to `DW_IC_DATA_CMD` as 2-byte address; queue 8 read commands; `i2c_poll_state = 1`.

### Phase 3: state 1 - drain header (8 bytes)

- Check `DW_IC_RXFLR ≥ 8`; if not, return (try again next frame).
- Read 8 bytes from `DW_IC_DATA_CMD`. Bytes [0..1] = total report length; if ≥9, queue more reads → state 2; else process now.

### Phase 4: state 2 - process full report

If `[hid_parsed_report_bytes] != 0` (parser ran successfully):

| # | File:Line | Action |
|---|---|---|
| a | i2c_hid.asm:1075 | `mov rsi, rdi` (report buf) |
| b | | `call hid_process_touchpad_report` |

### Phase 5: hid_process_touchpad_report (`kernel/drivers/hid_parser.asm`)

| # | Action |
|---|---|
| α | Read confidence bit from `[hp_found_fields & USAGE_CONFIDENCE]`; if 0, skip whole report (palm rejection - MEMORY.md #23) |
| β | Extract finger 0 X/Y at `hid_parsed_x_offset/y_offset` bits. |
| γ | Extract `contact_count` from `hid_parsed_count_*` field. |
| δ | If contact_count == 1: relative mouse: `mouse_x += (x - prev_x) * scale`. |
| ε | If contact_count == 2: extract finger 1 X (`hid_f1_x`); compute Manhattan `|f0x-f1x| + |f0y-f1y|`; delta vs `gesture_pinch_dist_prev` ÷ 4 → `mouse_pinch_delta` (threshold 8 px). |
| ζ | If contact_count ≥ 3: track X motion vs `gesture_scroll_ref_x`; threshold 40px → `gesture_swipe_dir = ±1`. |

## Consumer

`mouse_pinch_delta` is read by app code (e.g. zoom-on-pinch in image viewer / browser). Cleared after consumption.

## Audit-pass guarantees

- **Round 6 fix**: `i2c_hid_poll` `push rbx`/`pop rbx` added (was clobbering callee-saved rbx via `xor ebx, ebx` at L998 and several other rbx writes).
- **MEMORY.md #18**: report length 8 bytes (was 9, drain mismatch).
- **MEMORY.md #13**: state machine non-blocking - was 100ms/frame blocking probe.

## Failure modes

- I2C bus hang: drained via `DW_IC_CLR_TX_ABRT`; if 50 consecutive errors, full bus reset (`i2c_hid_bus_reset`).
- Confidence bit absent in descriptor → `hp_found_conf_bit_size == 0` → palm rejection disabled (treat all touches as real).
- Two fingers too close (delta < 8): no pinch event emitted.

## Invariants

- `i2c_poll_state ∈ {0, 1, 2}` and transitions only forward (0→1→2→0).
- `gesture_pinch_dist_prev` updated each 2-finger frame to current distance.
- `gesture_scroll_ref_x` updated after each emitted swipe so sequential swipes can be detected.
- `hid_f1_x` only valid when contact_count ≥ 2 in the just-parsed report.
