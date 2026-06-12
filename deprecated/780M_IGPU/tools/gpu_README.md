# tools/gpu - GFX11 (Strix Point, gfx1150) bring-up scaffolding

Preparation work for the Tier-3 GPU effort tracked in
[`docs/STATUS.md`](../../docs/STATUS.md#tier-3--gfx11-gc-115-bring-up-months-high-risk).
None of this code talks to the hardware yet - it produces the
*ingredients* (PM4 byte streams, shader blobs, register offsets) that
the future ring-submission code will consume.

## Layout

| Path                                          | Purpose                                                     |
|-----------------------------------------------|-------------------------------------------------------------|
| [`pm4.py`](pm4.py)                            | Pure-Python builder for PM4 type-3 packets.                 |
| [`test_pm4.py`](test_pm4.py)                  | Unit tests - verifies bit layouts against the AMD spec.     |
| [`shaders/textured_quad_vs.s`](shaders/textured_quad_vs.s) | Hand-written GFX11 vertex shader (VertexID-driven quad).    |
| [`shaders/textured_quad_ps.s`](shaders/textured_quad_ps.s) | Matching pixel shader (texture sample → MRT0).              |
| [`build_shaders.ps1`](build_shaders.ps1)      | Compiles `.s` → `.bin` via clang+llvm-objcopy; emits `.dis`.|
| [`../../src/include/amdgpu_regs.inc`](../../src/include/amdgpu_regs.inc) | NASM-includable register map (GC 11.0, MMHUB 3.0, MP 13).   |
| [`../../src/resources/gpu/`](../../src/resources/gpu/) | Compiled shader blobs (committed for reproducible builds).  |

## How the pieces fit

```
              ┌──────────────────────┐
              │ amdgpu_regs.inc      │  (data)
              └──────────┬───────────┘
                         │ register offsets
                         ▼
┌─────────────┐   ┌─────────────────────┐   ┌──────────────────┐
│ pm4.py      │──▶│ PM4 byte stream     │──▶│ CP indirect buf  │
└─────────────┘   │ (SET_*_REG, DRAW...)  │   │ (future code)    │
                  └─────────────────────┘   └──────────────────┘
                                                     ▲
              ┌──────────────────────┐               │
              │ textured_quad_*.bin  │───────────────┘
              │ uploaded to VRAM,    │  PGM_LO/HI point CP at them
              │ pointed at by SPI    │
              └──────────────────────┘
```

## Run the PM4 tests

```powershell
python tools\gpu\test_pm4.py
```

13 tests, no dependencies beyond stdlib. Should complete in ~10 ms.

## Build the shader blobs

```powershell
powershell -ExecutionPolicy Bypass -File tools\gpu\build_shaders.ps1
```

Requires LLVM ≥ 17 with the AMDGPU target (`winget install LLVM.LLVM`).
The script emits raw `.text` payloads into `src/resources/gpu/` and
human-readable disassemblies into `build/gpu/` for spot-checking
against the AMD GFX11 ISA reference.

## Future-proofing notes

* **Opcode table is data, not control flow.** Adding a new PM4 packet
  is a one-liner in `pm4.py` - define `IT_FOO` and a small wrapper
  on `PM4Builder`. Don't grow the existing wrappers with new flags.
* **Shader builds are independent.** Drop a new `.s` into
  `shaders/`; `build_shaders.ps1` picks it up via glob.
* **Register map is incrementally expanded.** When bring-up reaches
  PSP front-door / GMC / MEC, add the registers used by that block
  with a comment citing the upstream Linux header.
* **No hardware contact yet.** All artifacts here are
  unit-testable / disassemblable on a build box without a GPU.
