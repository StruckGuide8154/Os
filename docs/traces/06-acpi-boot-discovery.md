# Trace 06 - ACPI Boot Discovery: RSDP → XSDT → MADT → IOAPIC

## Entry

`kmain` calls `acpi_init` after `pit_init` and before `apic_init`/`ioapic_init`.

## Step 1: RSDP find (`kernel/arch/rsdp.asm`)

| # | File:Line | Action |
|---|---|---|
| 1 | rsdp.asm:14-17 | save rbx/rcx/rsi/rdi |
| 2 | rsdp.asm:20-30 | scan 0xE0000..0xFFFFF on 16-byte boundaries for "RSD PTR " (8-byte signature) |
| 3 | rsdp.asm:35-38 | EBDA segment from `[0x040E]` shl 4; if 0, fail |
| 4 | rsdp.asm:39-48 | scan 1KB at EBDA |
| 5 | returns rax = RSDP pointer or 0 |

**Round 8 fix**: `mov rcx, 0x1FFFF / 16` was 8191 paragraphs - last paragraph at 0xFFFF0 missed. Now `0x20000/16` = 8192.

## Step 2: ACPI table walk (`kernel/arch/acpi.asm`)

| # | File:Line | Action |
|---|---|---|
| 6 | acpi.asm:26-28 | rax = RSDP; if 0, return |
| 7 | acpi.asm:31-38 | XSDT pointer at RSDP+24 (qword); if 0, fall back to RSDT at RSDP+16 (dword zero-extended into rsi) |
| 8 | acpi.asm:45-46 | ecx = table length - 36 (header) |
| 9 | acpi.asm:48-60 | XSDT vs RSDT: shr ecx,3 (qword entries) or shr ecx,2 (dword); rbx = first entry |
| 10 | acpi.asm:62-93 | loop_tables: load entry pointer (qword for XSDT, dword for RSDT); switch on signature 'APIC'/'MCFG'/'FACP' |

## Step 3: MADT parse (`kernel/arch/madt.asm`)

`acpi.asm:95-100`: push rsi; `mov rsi, rdi (MADT ptr); call madt_init; pop rsi`

| # | File:Line | Action |
|---|---|---|
| 11 | madt.asm:23-29 | push rbx/rcx/rdx/rsi/rdi/r8 |
| 12 | madt.asm:41-44 | ecx = table length; rbx = first entry (rsi+44); rcx = end ptr (rsi+length) |
| 13 | madt.asm:46-48 | scan_loop: `cmp rbx, rcx; jae .done` |
| 14 | madt.asm:50-62 | type byte → dispatch: 0/9 = LAPIC/x2APIC, 1 = IOAPIC, 2 = ISO |
| 15 | madt.asm:64-81 | LAPIC: if enabled, store APIC ID into `madt_lapic_ids[edi]` (Round 8 fix: was using rcx, clobbering end ptr) |
| 16 | madt.asm:102-108 | IOAPIC: `mov [ioapic_base], rax` from entry+4 |
| 17 | madt.asm:130-132 | next: `add rbx, rdx` (entry length) |

**Round 8 fix critical**: line 73/77/92/96 used `mov ecx, [count]` which clobbered low 32 bits of rcx (end pointer). Loop terminated after first enabled CPU. Switched to edi/rdi.

## Step 4: FACP / DSDT parse for touchpad

`acpi.asm:109-167` `.handle_facp`:
- DSDT pointer at FADT+40; `aml_init` sets scan bounds
- `aml_find_object('ELAN' / 'SYNA' / 'FTE')` - Round 10 fix: SYNA found-result was being overwritten by next FTE search (wrong jz/jnz polarity)
- On match: scan 1024 bytes for ResourceDescriptor 0x86 (Memory32Fixed → spi_base) and 0x89 (Extended IRQ → touchpad_irq)

## Step 5: APIC + IOAPIC init

After `acpi_init` returns, `kmain` calls `apic_init` (apic.asm) then `ioapic_init` (ioapic.asm).

- `apic_init`: rdmsr 0x1B → mask out lower 12 bits → `lapic_base`. **Round 8 fix**: combine EDX:EAX before mask (`shl rdx,32 / or rax,rdx / and rax,~0xFFF`). Without this, lapic_base is wrong if APIC base ≥ 4 GB.
- `ioapic_init`: routes GSI 0..15 → vectors 32..47 in a loop. **Round 4 fix**: loop counter was r8 but `ioapic_set_irq → ioapic_write` overwrites r8 with `[ioapic_base]` (~0xFEC00000). Loop terminated after 1 iteration. Switched to rbx.

## Failure modes

- No RSDP → `acpi_init` returns silently; APIC/IOAPIC won't be set up. Kernel still works via PIC.
- Truncated MADT (length corrupt) → loop may overshoot real entries; mitigated by `cmp rbx, rcx`.
- AML not parseable → touchpad info absent; fall back to default touchpad_irq=18 and spi_base=0xFEC00000 (which used to misfire on IOAPIC, MEMORY.md #26 added DW SPI signature check).

## Invariants

- After `acpi_init`: `ioapic_base`, `madt_enabled_cpu_count`, `madt_lapic_ids[]`, `spi_base`, `touchpad_irq` populated (or zero if absent).
- `lapic_base` is page-aligned.
- All MADT entries scanned exactly once.
