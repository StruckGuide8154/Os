# Track 5 G1 — verifying the REAL Intel VT-x back-end (`tested-accel`)

`src/kernel/grithlk/mon_hal_vmx_backend.ghl` emits real `VMXON / VMCLEAR /
VMPTRLD / VMWRITE / VMLAUNCH / VMRESUME`. Those instructions **#UD on QEMU-TCG**,
which implements no VMX root mode, so the normal CI boot (`test_*` + the GHL
security guards) deliberately does **not** execute this path — it only proves the
module compiles and assembles. Promoting the Track 5 doc tag from
`tested-accel`-PENDING to `tested-accel` requires running on a host where VMX
actually traps. This file is that procedure.

## What "verified" means here

1. The machine enters VMX root mode (`vmx_enter_root` returns 0 — real `VMXON`).
2. `VMLAUNCH` succeeds: `vmx_backend_status()` reads `VMXST_LAUNCHED (6)` and the
   kernel keeps running (it is now the guest, behavior unchanged).
3. The CR-trap floor bites: a deliberate `mov cr0, rax` that clears CR0.WP from
   ring-0 takes a VM-exit (basic reason 28) into `vmx_exit_trampoline`, the write
   is dropped, and `.text` stays read-only. Without the monitor the same write
   would succeed.

## Host options (pick one)

### A. Nested KVM (most reproducible)
On a Linux box with an Intel CPU:

```sh
# one-time: allow nested VMX
echo 'options kvm_intel nested=1' | sudo tee /etc/modprobe.d/kvm.conf
sudo modprobe -r kvm_intel && sudo modprobe kvm_intel
cat /sys/module/kvm_intel/parameters/nested      # must print Y

# run Grit's UEFI image with VMX exposed to the guest
qemu-system-x86_64 -enable-kvm -cpu host,+vmx \
  -machine q35 -m 2048 \
  -drive if=pflash,format=raw,readonly=on,file=OVMF_CODE.fd \
  -drive format=raw,file=build/grit.img \
  -serial stdio
```

### B. Real Intel silicon
Boot `build/grit.img` from USB on an Intel machine with VT-x enabled in firmware
(no Hyper-V / other hypervisor owning VMX). Watch COM1 / the on-screen monitor
status row.

## Arming it

The back-end is dead code until `vmx_backend_arm(...)` is called. For the
verification run, gate the call behind the existing detect so it only fires where
VMX is usable (it already returns `MONHAL_TIER_INTEL_VTX`):

- allocate four identity-mapped 4 KiB pages (VMXON region, VMCS, EPT PML4, zeroed
  MSR bitmap) and build the identity EPT (perms from `mon_hal_s2_map_perms`);
- fill the capture block (CS/SS/DS/ES/FS/GS selectors in that order at
  `CAP_ES_SEL`-indexed slots, TR base, and the resume RSP/RIP/RFLAGS) from a tiny
  boot asm stub (`mov ax,cs` … — the values GHL has no intrinsic for);
- call `vmx_backend_arm(cap, vmxon_pa, vmcs_pa, eptp_pml4_pa, msr_bitmap_pa,
  host_rsp)`.

## Pass / fail

- `vmx_backend_status() == 6 (VMXST_LAUNCHED)` and the GUI/serial stay live →
  G1 launch verified. Record the host + CPU in the Track 5 doc and flip the tag.
- Any `1..5` status → bring-up failed at that stage (feature-control, VMXON, VMCS
  load, VMWRITE, or VMLAUNCH); read `IA32_VMX` exit-error via `vmread(0x4400)`.
- WP-clear test: after launch, a ring-0 `mov cr0, rax` clearing bit 16 followed
  by a write to a `.text` page must **fault / be dropped**, not patch. That is
  the floor-disable defense proven.

Until this run lands, the Track 5 doc keeps items 2-4 at `modeled` /
`tested-tcg` / `tested-accel`-PENDING — never claim HW enforcement from a TCG CI
boot (Track 5 honesty rule).
