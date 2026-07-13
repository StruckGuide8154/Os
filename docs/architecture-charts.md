# Grit Architecture Charts

Quick reference diagrams: what runs where, what's sandboxed inside what, and
who talks to whom. Generated from the current design tracks.

---

## 1. Privilege rings — who sits where

```mermaid
flowchart TB
    subgraph R3["Ring 3 — user mode (sandboxed)"]
        APPS["Apps (.ghl)\nper-app syscall capability bitmap"]
        subgraph DRV["Userspace drivers (Track 8)"]
            BAT["battery"]
            NIC["rtl8156 NIC"]
            IN["input / HID"]
            DISP["display"]
            AUD["HDA audio class driver"]
        end
    end

    subgraph R0["Ring 0 — kernel"]
        SYS["syscall dispatcher\n(default-deny floor CAP_CORE)"]
        BROKER["driver_host broker\n(DMA grant table, PnP match)"]
        WM["window mgr / desktop / taskbar (asm, authoritative)"]
        NET["net stack (arp/ip/udp/dns/dhcp, zero-asm GHL)"]
        FS["FAT16 (fat16_core.ghl, zero-asm)"]
        SCHED["priority scheduler + SMP workqueue"]
        NK["nested-kernel monitor (MMU+WP PTE guard)"]
    end

    subgraph SUB0["Below ring 0 — monitor tiers"]
        T5["Track 5: mon_hal\nVMX/SVM/EL2/RISC-V-H + IOMMU DMA confinement"]
        T6["Track 6: software '-1' compartment monitor\n(PT/KEY/HASH/CAP/DMA/LOAD)"]
    end

    subgraph HW["Hardware root"]
        T10["Track 10: USB-FPGA secure enclave\n(root-of-trust, anti-rollback floors, TRNG)"]
        FME["FME: Intel TME / AMD SME full-DRAM encrypt"]
    end

    APPS -->|syscall| SYS
    DRV -->|broker IPC only| BROKER
    BROKER --> SYS
    SYS --> SCHED
    SCHED --> NET & FS & WM
    R0 --> NK
    NK --> T5 & T6
    T5 & T6 --> T10 & FME
```

---

## 2. Driver sandboxing (Track 8) — what's confined and how

```mermaid
flowchart LR
    subgraph SANDBOX["Ring-3 driver sandboxes (one per driver)"]
        D1["battery"]
        D2["rtl8156 NIC"]
        D3["HID / input"]
        D4["display"]
        D5["HDA audio (class driver, ~90% machines)"]
    end

    BROKER["driver_host.ghl broker\n• frozen driver_inventory.txt (new in-kernel drivers impossible)\n• DMA grant table (G2 IOMMU-enforced)\n• PnP match-table controller"]

    KERN["Ring-0 kernel services"]

    D1 & D2 & D3 & D4 & D5 -->|"capability-scoped IPC\n(no direct MMIO/DMA)"| BROKER
    BROKER -->|"granted windows only"| KERN

    note["G1: --target driver gate at compile time\nG2: IOMMU confines driver DMA to granted pages"]
```

---

## 3. Trust chain (Track 2 / Track 7) — single public root

```mermaid
flowchart TB
    ROOT["Ed25519 public root of trust\n(Track 7: single root, HMAC chain removed)"]
    QUORUM["Threshold quorum\n(KQUORUM.ENV dual-approval ratchet)"]
    FLOOR["Anti-rollback floors\n(floor_store.ghl @ data.img LBA 2,\nRTC now-binding, forward ratchet)"]
    MANIFEST["Keyless SHA manifest\n(measured boot)"]

    KENV["KERNEL.ENV\n(loader-side envelope, measured handoff)"]
    APPENV["App envelopes (.ghl)\n25-case reject matrix"]

    ROOT --> QUORUM --> FLOOR
    FLOOR --> MANIFEST
    MANIFEST --> KENV
    MANIFEST --> APPENV
    KENV -->|"fail-closed KSG*"| BOOT["Boot / load"]
    APPENV -->|"envelope_verify_signed"| LOAD["App launch"]
```

---

## 4. Boot → lockdown sequence

```mermaid
flowchart LR
    UEFI["UEFI GOP framebuffer\n(no per-vendor GPU MMIO)"]
    --> LOADER["loader: KERNEL.ENV verify"]
    --> MB["measured_boot_init\n(signed manifest, no blob rehash)"]
    --> ASYNC["async device bring-up\n(USB HID / i2c / NIC on SMP worker)"]
    --> SMP["SMP AP bringup\n(batched INIT-SIPI, SMEP/SMAP/CR0.WP per core)"]
    --> JOIN["join device_enum_job"]
    --> LOCK["lockdown\n(W^X, nested-kernel monitor armed)"]
    --> GUI["desktop / taskbar live"]
```

---

## 5. Liveness / no-freeze protection

```mermaid
flowchart TB
    A["NO-FREEZE invariant:\nloop or fail, sandbox + terminate"]
    A --> B["Tier-1: BSP kernel-liveness watchdog\n(PIT tick force-recovers wedged main loop → r3guard pad)"]
    A --> C["Ring-3 callback deadman\n(per-slot in-flight guard, priority demote-then-kill)"]
    A --> D["GHL blocking-effect type system\n(nonblocking fn rejected if it can block/spin/lock)"]
    A --> E["kfault ring-0 recovery\n(longjmp guard wraps render_frame)"]
    A -.->|TODO| F["Tier-2: NMI/cli watchdog + bounded locks"]
```

---

> Diagrams render in any Mermaid-aware viewer (GitHub, VS Code Mermaid preview).
> Source tracks: see `docs/architecture-defense-in-depth.md` and per-track TODO docs.
