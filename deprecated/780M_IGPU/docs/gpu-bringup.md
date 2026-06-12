# GFX11 bring-up wave plan

Living document. Edit as waves land or the plan changes. Updated 2026-05-26.

The high-level goal is **iGPU-accelerated rendering** for the Strix Point
(gfx1150) target. Today every pixel is CPU `rep movsq`; full GFX bring-up
replaces that with PM4 packets to a CP GFX ring.

## Sequence

| Wave | Task | Status | Module                          | Verifies                          |
|------|------|--------|---------------------------------|-----------------------------------|
| W1.A | PCI scan for GPU device         | DONE (pre-existing) | `pci.asm`              | BAR0/BAR2 discovered              |
| W1.B | BAR0 mapped, decode enabled     | DONE | `amd_display.asm`               | MMIO reads return non-FF          |
| W1.C | IP-discovery walk (optional)    | SKIPPED - Linux header bases used directly via `amdgpu_regs.inc` | - | block bases sane on Strix |
| W1.D | DCN read-only probe             | DONE | `amd_dcn.asm`                   | safe head reads, version sniff    |
| W1.E | SMU mailbox primitive           | DONE (this wave)    | `gpu/amd_smu.asm` | `PPSMC_MSG_TestMessage` returns 1 |
| W1.F | MMHUB context-0 init shell      | DONE (folded into Task I) | `gpu/amd_gmc.asm` | base/start/end regs read back |
| W2.H | **SMU mailbox + GFX active**    | **VERIFIED on Strix HW (2026-05-26)** | `gpu/amd_smu.asm` (`smu_powerup_gfx`) | TestMessage acks; SCRATCH_REG0 round-trips. APU has no PowerUpGfx - replaced with TestMessage + DisallowGfxOff sequence. SMU is reached via NBIO SMN proxy (`gpu/amd_smn.asm`), not direct BAR0. |
| W2.I | **GFXHUB page tables (ctx 0)**  | **VERIFIED on Strix HW (2026-05-26)** | `gpu/amd_gmc.asm` (`gmc_init`)        | `GCVM_CONTEXT0_CNTL` readback = `0x01FFFC03`. NOTE: GFXHUB invalidate ENG0 does not ack (reserved for KIQ); skipped non-fatally. Fault status `0xE08ACFC9` after enable is expected - every GFX client starts translating through ctx 0 the moment it comes up and our 2 MiB window doesn't cover their probes. Real CP submissions will not fault because they translate addresses we control. |
| W2.J | **CP ring + doorbell**          | **VERIFIED on Strix HW (2026-05-26)** | `gpu/amd_cp_ring.asm` (`cp_ring_alloc`, `cp_ring_map_doorbell`) | `CP_RB0_CNTL` = `0x0A000A0D` round-trips; `CP_RB0_BASE` = `0x04004000` round-trips; BAR2 doorbell = `0x260010E0`. CP is still halted at `CP_ME_CNTL`; ring is configured and waiting for microcode. |
| W3.K | RLC microcode load              | CODE READY, un-gated (runs with any `-Gfx` build) - awaiting Strix HW ack | `gpu/amd_psp.asm`, `gpu/amd_psp_fwload.asm` | PSP GPCOM ring creates; `LOAD_IP_FW(RLC_G=8)` acks |
| W3.L | PFP/ME/MEC microcode + CP start | CODE READY, gated by `GRIT_GFX_WAVE3_L_FIRE` (`-GfxWave3L`). Blocked on shipping `GC115{PFP,ME,MEC}.BIN` into `assets/firmware/`. After PSP acks all three, `cp_gfx_start_nop` clears `CP_ME_CNTL`, drops `RB_NO_UPDATE`, writes a 2-dword PM4 NOP and polls `CP_RB0_RPTR` for advance. | `gpu/amd_psp_fwload.asm`, `gpu/amd_cp_ring.asm` | All three PSP acks status==0; `CP_RB0_RPTR` reaches 2 |
| W3.M | MES scheduler bring-up          | DEFERRED - needs KIQ ring (MQD) + MES INIT command + `gc_11_5_0_mes.bin`/`mes_kiq.bin` blobs | -                                 | MES doorbell ack                  |
| W4.N | First triangle (textured quad)  | TODO | -                                 | pixels in CB0                     |

## Module ownership rule

One wave entry → one well-named entry function. The orchestrator
(`gfx_bringup`) is the only place tasks are stitched together. New waves
should add a new entry to the orchestrator, not in-line work into existing
modules.

## Failure handling

Every stage entry returns `al = 0/1`. On failure, `gpu_bringup_state` is
left at the last successful state and `gfx_last_stage` records the failing
stage letter. The boot diagnostic overlay can surface both without any
extra plumbing.

A retry of `gfx_bringup()` re-walks from the current state forward. Stages
prior to `gpu_bringup_state` short-circuit.

## How to enable on a build

```powershell
# UEFI build with bring-up included (still requires explicit call from main):
$env:KERNEL_EXTRA_DEFS = '-dGRIT_GFX_BRINGUP'
powershell -ExecutionPolicy Bypass -File scripts\build\build_uefi.ps1
```

Then add a single call in `src/kernel/core/main.asm`, *after* the existing
`call amd_dcn_probe`:

```nasm
%ifdef GRIT_GFX_BRINGUP
    extern gfx_bringup
    call gfx_bringup
    ; al = post-walk state; surface via klog if you want diagnostics.
%endif
```

That call is intentionally NOT committed today - bring-up should be
opt-in even within the gated build until at least one hardware run has
confirmed the H→I→J path on Strix.

## Out of scope here

* DCN flip queue (Tier 2 in `docs/STATUS.md`). Independent track; does not
  share the bring-up state machine.
* DMUB / backlight (parked). Different microcontroller, different mailbox.
* Userspace 3D stack. PM4-by-hand is the only consumer in scope.
