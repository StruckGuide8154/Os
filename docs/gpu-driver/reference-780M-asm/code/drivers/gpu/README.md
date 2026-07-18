# gpu/ - AMD GFX11 (Strix Point, gfx1150) kernel-side bring-up

Wave-2 modules that take the GPU from "BAR0 mapped, DCN read-only probed"
to "CP GFX ring programmed, doorbell mapped". The CP itself is **not**
started here - that needs PFP/ME/CE microcode load (a later wave).

## Status

Gated. The default build does not include any of this. To enable:

```powershell
$env:GRIT_GFX_BRINGUP = 1
nasm -dGRIT_GFX_BRINGUP ...   # or pass via build_uefi.ps1 KernelDefines
```

Even with the flag, hardware contact only happens when something calls
`gfx_bringup` from `main.asm`. Today nothing does.

## Module map

| File              | Wave   | Role                                                    |
|-------------------|--------|---------------------------------------------------------|
| `amd_gpu_mmio.asm`| W1     | `gpu_mmio_r32/w32/wait_eq` over BAR0. State machine root.|
| `amd_smu.asm`     | W1.E + Task H | SMU mailbox + `PPSMC_MSG_PowerUpGfx`.            |
| `amd_gmc.asm`     | W1.F + Task I | MMHUB context-0 PT (flat 2 MiB identity map).    |
| `amd_cp_ring.asm` | Task J | CP ring buffer regs + BAR2 doorbell capture.            |
| `amd_psp.asm`     | Wave 3 | PSP SOS GPCOM ring + TMR primitive.                     |
| `amd_psp_fwload.asm` | Task K/L | PSP `LOAD_IP_FW` staging for RLC/CP blobs.        |
| `amd_gfx.asm`     | -      | Orchestrator: walks H → I → J, records last stage.      |

Shared layout lives in `src/include/amdgpu_gfx.inc`. PPSMC opcodes are in
`src/include/amdgpu_ppsmc.inc`. Register dword offsets are in
`src/include/amdgpu_regs.inc`.

## Wave plan

See [`docs/gpu-bringup.md`](../../../../docs/gpu-bringup.md) for the
end-to-end sequence and what still needs to land beyond Task J.

## Design rules (future-proof)

1. **Every module is idempotent and gated by `gpu_bringup_state`.** A re-call
   after partial success is a no-op past the completed stage.
2. **MMIO goes through `gpu_mmio_*`.** No module reaches into BAR0 directly;
   that keeps the BAR0-acquisition path single-sourced.
3. **Memory layout is declared once** (`amdgpu_gfx.inc`). Don't sprinkle
   physical addresses across modules.
4. **No hardware contact at include time.** All side effects happen behind
   `gfx_bringup()`.
5. **PIT-tick timeouts only.** Real Strix HW vs QEMU diverges ~5000× on raw
   loops; everything here uses `tick_count` deadlines.
