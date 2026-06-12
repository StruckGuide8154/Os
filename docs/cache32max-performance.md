# GritOS Cache32Max Performance Profile

`Cache32Max` is an experimental profile for cache-first development on an
8-core Ryzen-class system. It keeps the normal boot profile unchanged while
adding a strict 32 MB QEMU target and serial diagnostics for CPU/cache,
frequency, memory layout, and SMP status.

## Build and Run

```powershell
.\scripts\build\build_uefi.ps1 -PerfProfile Cache32Max
.\scripts\run\run_uefi.ps1 -PerfProfile Cache32Max
```

The profile passes `GRIT_CACHE32_MAX` to NASM and runs QEMU with:

- `32M` guest memory on BIOS
- `36M` guest memory on UEFI because this OVMF build exits below that floor
- `8,sockets=1,cores=8,threads=1` SMP topology

Normal `Default` builds and runs keep their existing memory map and 512 MB QEMU
RAM default.

## Speed Tiers

| Tier | Ownership |
|---|---|
| L1-hot | IRQ stubs, syscall entry/return, scheduler fast path, input flags, per-core state |
| L2-warm | HID parsing, AP worker queues, window metadata, font/text primitives, FAT metadata |
| L3/LLC GUI | Backbuffer, saved backbuffer, cursor/window/event GUI composition state |
| RAM-cold | App arenas, device DMA rings, FAT file buffers, disk data, debug logs |

The profile does not turn CPU cache into addressable RAM. It separates hot,
warm, LLC-sized, and cold regions so repeated work has a smaller natural cache
working set.

## Fixed Layout

For `GRIT_CACHE32_MAX`:

- Hot kernel state remains below 4 MB.
- GUI LLC arena is `0x1000000..0x1700000`.
- XHCI cold DMA buffers are based at `0x1700000`.
- App arenas are based at `0x1800000`.
- Kernel syscall stacks are based at `0x2100000`.
- XHCI cold DMA buffers move to `0x1900000..0x19F0000`.
- FAT16 cold buffers move to `0x1A00000..0x1A31000`.
- Strict RAM cap constant is `0x2000000` bytes.

## Serial Diagnostics

After boot, serial control bytes can request diagnostics:

| Command | Output |
|---|---|
| `0x01` then `p` | `CPU:`, `CACHE:`, `FREQ:`, `MEMCAP:`, `SMP:` |
| `0x01` then `m` | `MEMCAP:` arena summary |
| `0x01` then `s` | `SMP:` detected/target/started/alive/parked counts |
| `0x01` then `v` | `GPU780M:`/`GPUAMD:` PCI identity plus `AMDDISP:` provider state |
| `0x01` then `b` | `BENCH:` short CPU benchmark cycle delta |

`FREQ:` reports a TSC delta over one PIT tick when interrupts are enabled. It is
a measurement aid, not direct turbo control.

The `GPU780M:` probe only reads PCI config space. It does not enable the device,
write the command register, or touch BAR MMIO. If the exact `1002:15BF` 780M ID
is not present, it also prints `GPUAMD:` for the first AMD display controller it
sees so hardware can still be identified 1:1. `BAR0:` and `CMD:` are reported as
read-only bring-up metadata for the eventual hardware init path.
`AMDDISP:` reports whether the AMD display provider claimed the boot framebuffer
and the native firmware/GOP mode it will accept for mode setting.

## SMP Status

The current milestone has cacheline-aligned per-core state records, a real-mode
AP trampoline, and Local APIC INIT-SIPI-SIPI startup. Cache32Max builds enable
`GRIT_CACHE32_AP_STARTUP` and `GRIT_ENABLE_RING3_AP`; APs enter long mode,
update their heartbeat/state records, initialize their ring-3 syscall/TSS
state, and run `smp_worker_loop`. IRQ and device ownership remain on the BSP,
but app callbacks are submitted to each process `home_core`.
