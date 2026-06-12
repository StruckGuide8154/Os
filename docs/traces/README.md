# Granular Data-Path Traces

Each file traces one specific end-to-end data path through Grit, with file:line references, register conventions, and the audit-pass guarantees that hold for that path.

These are independently testable: each trace can be exercised in isolation by triggering its entry point.

| # | Trace | Entry | Endpoint |
|---|---|---|---|
| 01 | [PS/2 mouse click](01-ps2-mouse-click.md) | IRQ12 | cursor redraw + click dispatch |
| 02 | [PS/2 keystroke](02-keyboard-keystroke.md) | IRQ1 | kb_buffer → focused-window key handler |
| 03 | [PIT tick](03-pit-tick-time.md) | IRQ0 | tick_count + wall clock |
| 04 | [Frame render → flip](04-frame-render-flip.md) | main loop | back-buffer → vram |
| 05 | [FAT16 file read](05-fat16-file-read.md) | SYS_FS_READ | ATA sector → user buffer |
| 06 | [ACPI boot discovery](06-acpi-boot-discovery.md) | acpi_init | ioapic_base + lapic_base + spi_base |
| 07 | [Touchpad pinch gesture](07-touchpad-pinch-gesture.md) | i2c_hid_poll | mouse_pinch_delta |
| 08 | [xHCI port reset → ADDRESS_DEVICE](08-xhci-port-reset-address.md) | xhci_init | endpoint ready, first read queued |
| 09 | [Window create → first paint](09-window-create-paint.md) | SYS_WM_CREATE | titlebar + content visible |
| 10 | [App launch → user iretq](10-app-launch-iretq.md) | app_launch | first user-mode instruction executes |

## Reading order

For boot path: 06 → 03 → 08 → 04
For input flow: 01 + 02 + 07 → 04
For app lifecycle: 10 → 09 → 04 → (apps issue syscalls like 05)

## Maintenance

Each trace lists the audit-pass round that touched the relevant code. When fixing a bug along one of these paths, update the corresponding trace's "Audit-pass guarantees" section and re-state the invariants.

See [../audit-checklist.md](../audit-checklist.md) for the per-file change log + sha256.
