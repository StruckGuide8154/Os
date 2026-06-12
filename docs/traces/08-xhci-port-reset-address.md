# Trace 08 - xHCI Port Reset → ADDRESS_DEVICE → Endpoint Ready

## Entry

`xhci_init` from `kmain` after PCI scan finds an xHCI controller.

## Step 1: controller setup (`kernel/drivers/xhci.asm`)

- BAR0 → `xhci_op_base`, capability registers parsed (HCSPARAMS for max ports/slots/scratchpad).
- `xhci_reset` sets HCRST bit, waits HCH=0 with PIT 50-tick deadline (xhci.asm:122-137).
- DCBAA, command ring, event ring, scratchpad pages allocated; pointed to via op regs.

## Step 2: port enumerate (`xhci_find_port`)

`xhci_find_port` (xhci.asm:998):

| # | File:Line | Action |
|---|---|---|
| 1 | xhci.asm:1000-1003 | push rsi/rcx/rdx/rbx |
| 2 | xhci.asm:1005-1006 | `mov rsi, [xhci_op_base]; add rsi, 0x400` (port reg base) |
| 3 |   | iterate ports 0..MaxPorts-1; check `XHCI_PORTSC_CCS` (current connect status) |
| 4 |   | port power-on if not already (PP bit); short PIT wait |

## Step 3: port reset

| # | File:Line | Action |
|---|---|---|
| 5 | xhci.asm:1100-1105 | read PORTSC; mask change bits + PED; |
| 6 | xhci.asm:1108-1115 | speed ≥ 4 → WPR (warm reset bit 31), else PR |
| 7 | xhci.asm:1122-1123 | write PORTSC |
| 8 | xhci.asm:1125-1135 | **PIT-deadline wait**: rbx = tick_count + 60 (600 ms); poll PRC or WRC bit (Round 5) |
| 9 | xhci.asm:1138-1143 | clear PRC|WRC by writing them back (RW1C); other change bits left untouched (write 0 = no-op) |
| 10 | xhci.asm:1146-1149 | re-read speed (Speed field bits 10:13) → `xhci_port_speed` |
| 11 | xhci.asm:1151-1155 | post-reset 20 ms dwell via PIT (2 ticks; Round 5) |
| 12 | xhci.asm:1156-1175 | wait PED with PIT 50-tick deadline; read final speed |

(Pre-Round 5: lines 1126/1152/1162 were CPU spins of 50000/20000/50000 - ~50 µs to 5 ms on fast cores, way under USB-spec 10 ms reset hold. Devices never enumerated on real Strix Point hardware.)

## Step 4: ENABLE_SLOT command

Submit Enable Slot TRB to command ring; doorbell to slot 0; wait command-completion event with PIT-deadline (Round 3 prerequisite). Returns slot ID in event TRB.

## Step 5: ADDRESS_DEVICE command

- Allocate Input Context (4 KB, zeroed).
- Set Add Context flags A0|A1 (slot + EP0).
- Slot Context: route, speed, context entries=1, root hub port.
- EP0 Context: control type, MaxPacketSize per speed (8/64/512), TR Dequeue Pointer = transfer ring base.
- DCBAA[slot] = output device context.
- Submit ADDRESS_DEVICE TRB; wait completion (PIT 200 ticks = 2 s - Round 3, MEMORY.md #31). Real-HW takes 50-500 ms; pre-fix CPU loop fired in 0.6 ms.

## Step 6: enumerate config / endpoints

- GET_DESCRIPTOR(Device) via control transfer.
- SET_CONFIGURATION(1).
- For each interface, call `xhci_configure_endpoint(EP_num, MaxPacketSize, Interval)` - Round 3 fix added missing `push r12-r14`. Function uses r12-r14 as scratch for EP num / packet size / interval.

## Step 7: queue first read

For HID interrupt-IN endpoint: queue Normal TRB pointing to `XHCI_MOUSE_BUF_ADDR`, length = report size; doorbell. Subsequent events arrive on event ring with slot ID in EBX bits 31:24 (MEMORY.md #28).

## Audit-pass guarantees

- All long waits PIT-deadlined: cmd-ring submit, completion wait, port reset, post-reset dwell, PED wait. None depend on CPU clock speed.
- `xhci_configure_endpoint` preserves r12-r14 (callee-save).
- Slot-ID routing (slot1 vs slot2 mouse) at event dispatch (`usb_poll_mouse`) - MEMORY.md #28.

## Failure modes

- Port doesn't power: 30-ms PIT wait then skip port.
- ADDRESS_DEVICE timeout: log error, abandon port, try next.
- Wrong MaxPacketSize: device may NAK forever; current code uses speed-derived defaults.

## Invariants

- One Slot per attached device. DCBAA[slot] always points to valid output context.
- Transfer ring dequeue/enqueue ratio matches event-ring consumption.
- Event ring DCS (Dequeue Cycle State) toggles each ring wrap.
