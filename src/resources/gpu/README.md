# GPU shader blobs

Pre-compiled GFX11 shader binaries. Each `.bin` is the raw `.text`
section of an AMDGCN ELF object, ready to be uploaded to VRAM and
pointed at by `SPI_SHADER_PGM_LO_*` / `PGM_HI_*`.

These files are checked in so the main build (`build_uefi.ps1`) does
not depend on LLVM. To regenerate after editing
`tools/gpu/shaders/*.s`:

```powershell
powershell -ExecutionPolicy Bypass -File tools\gpu\build_shaders.ps1
```

`tools/gpu/build_shaders.ps1` also writes a human-readable disassembly
to `build/gpu/*.dis` - use that to verify the binary against the AMD
GFX11 ISA spec before committing.

| File                     | Source                                       |
|--------------------------|----------------------------------------------|
| `textured_quad_vs.bin`   | `tools/gpu/shaders/textured_quad_vs.s`       |
| `textured_quad_ps.bin`   | `tools/gpu/shaders/textured_quad_ps.s`       |

The `.bin` files are populated by the build script and are not yet
committed - first run requires LLVM ≥ 17 with the AMDGPU target.
