; ============================================================================
; NexusOS — architectural register / MSR / MMIO-base constants (src/kernel/arch)
; ----------------------------------------------------------------------------
; Named values for the magic literals previously baked into the APIC, I/O APIC
; and ACPI-RSDP drivers. Each constant cites the spec section it comes from so
; the value is traceable, not just named. Definitions live here; the .asm files
; reference the names (maintainability-todo.md §4.2).
; ============================================================================

%ifndef ARCH_REGS_INC
%define ARCH_REGS_INC

; --- MMIO base addresses ----------------------------------------------------
; Local APIC default physical base. Power-on reset value of IA32_APIC_BASE
; (bits 35:12); QEMU and real hardware both come up here before relocation.
; Intel SDM Vol.3 §10.4.4 "Local APIC Status and Location".
LAPIC_DEFAULT_BASE      equ 0xFEE00000
; I/O APIC default physical base.
; Intel I/O APIC datasheet §3.0 (IOAPIC default base FEC0_0000h); also
; Intel SDM Vol.3 §10.5.4 "I/O APIC".
IOAPIC_DEFAULT_BASE     equ 0xFEC00000

; --- Model-Specific Registers (ECX selector for RDMSR/WRMSR) ----------------
; Extended Feature Enable Register. Intel SDM Vol.4 Table 2-2 (IA32_EFER,
; MSR address C000_0080h); AMD APM Vol.2 §3.1.7.
IA32_EFER_MSR           equ 0xC0000080
; Page Attribute Table MSR. Intel SDM Vol.4 Table 2-2 (IA32_PAT, MSR
; address 277h); Intel SDM Vol.3 §11.12.4.
IA32_PAT_MSR            equ 0x277

; --- IA32_PAT canonical type layout -----------------------------------------
; Per-DWORD encoding written to IA32_PAT: slot0=WB(06), slot1=WC(01),
; slot2=UC-(07), slot3=UC(00) per 32-bit half. This is the canonical Linux
; layout so the FB leaf PTE patched by fbperf_wc_activate reads as WC.
; Intel SDM Vol.3 §11.12.4 Table 11-10 (PAT memory-type encodings).
IA32_PAT_CANONICAL_LO   equ 0x00070106
IA32_PAT_CANONICAL_HI   equ 0x00070106

; --- CR0 control bit --------------------------------------------------------
; CR0.PG (bit 31) — enable paging. Intel SDM Vol.3 §2.5 "Control Registers".
CR0_PG                  equ 0x80000000

; --- Local APIC ICR command words (written to LAPIC + 0x300 / ICR low) ------
; Intel SDM Vol.3 §10.6.1 "Interrupt Command Register (ICR)".
; All-excluding-self shorthand (bits 19:18=11b), Fixed delivery, level=assert,
; vector 0x31 (49) — used to wake idle AP workqueue workers.
LAPIC_ICR_WAKE_WORKERS  equ 0x000C4031
; AP startup IPI sequence (SDM Vol.3 §10.6.1 / §8.4.4 INIT-SIPI-SIPI):
;   INIT assert (delivery mode 101b, level=assert, trigger=level)
LAPIC_ICR_INIT_ASSERT   equ 0x00004500
;   INIT de-assert (level=de-assert, trigger=level)
LAPIC_ICR_INIT_DEASSERT equ 0x00008500
;   STARTUP IPI (delivery mode 110b) with vector 0x08 -> trampoline @ 0x8000.
LAPIC_ICR_STARTUP       equ 0x00004608

; --- 64-bit GDT descriptors (flat segments used by the AP trampoline) -------
; Standard flat-segment qword descriptors. Intel SDM Vol.3 §3.4.5 "Segment
; Descriptors" (base=0, limit=0xFFFFF, G=1).
GDT_DESC_CODE32         equ 0x00CF9A000000FFFF  ; 32-bit ring-0 exec/read (DB=1)
GDT_DESC_DATA32         equ 0x00CF92000000FFFF  ; 32-bit ring-0 read/write
GDT_DESC_CODE64         equ 0x00AF9A000000FFFF  ; 64-bit ring-0 exec/read  (L=1)

; --- ACPI RSDP BIOS scan window (legacy fallback) ---------------------------
; ACPI 6.x §5.2.5.1 "Finding the RSDP on UEFI-Enabled Systems / legacy BIOS":
; scan the main BIOS area E0000h..FFFFFh (a 0x20000-byte / 128 KiB window) on
; 16-byte boundaries for the "RSD PTR " signature.
RSDP_BIOS_SCAN_BASE     equ 0xE0000
RSDP_BIOS_SCAN_LEN      equ 0x20000

%endif ; ARCH_REGS_INC
