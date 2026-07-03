// ============================================================================
// textured_quad_vs.s — GFX11 (gfx1150, Strix Point) vertex shader
// ----------------------------------------------------------------------------
// Pairs with textured_quad_ps.s.
//
// Renders a fullscreen-ish textured quad driven by DRAW_INDEX_AUTO with 4
// auto-indices and primitive type TRISTRIP. No vertex buffer fetch: the
// VS computes position and UV from VertexID directly, so no VBO needs to
// be bound. This keeps the bring-up shader self-contained — useful for
// the very first triangle on the hardware before we have a vertex-input
// layer.
//
// Hardware ABI assumed (matches what the PM4 setup in src/gpu/ will
// program):
//   SGPRs in : s0  = VertexID base (we ignore, draw_auto provides VID via VGPR)
//              ... (user SGPRs configurable via SPI_SHADER_USER_DATA_VS_*)
//   VGPRs in : v0  = VertexID (provided by SPI when ENABLE_VTX_ID = 1)
//   VGPRs out: v0..v3 = clip-space position xyzw  (slot 0)
//              v4..v5 = uv                         (parameter slot 0)
//
// Position table (NDC, CCW with backface cull off):
//   vid=0 -> (-1,-1)  uv (0,1)
//   vid=1 -> (+1,-1)  uv (1,1)
//   vid=2 -> (-1,+1)  uv (0,0)
//   vid=3 -> (+1,+1)  uv (1,0)
//
// Encoding: x = (vid & 1) ? +1 : -1
//           y = (vid & 2) ? +1 : -1
//           u = (vid & 1) ? 1.0 : 0.0
//           v = (vid & 2) ? 0.0 : 1.0
//
// Build:
//   clang -x assembler-with-cpp -target amdgcn-amd-amdpal \
//         -mcpu=gfx1150 -mcode-object-version=5 \
//         -c textured_quad_vs.s -o textured_quad_vs.o
//   llvm-objcopy -O binary --only-section=.text \
//         textured_quad_vs.o textured_quad_vs.bin
//   llvm-objdump -d --mcpu=gfx1150 textured_quad_vs.o > textured_quad_vs.dis
//
// The build_shaders.ps1 wrapper at tools/gpu/ does all three steps.
// ============================================================================

    .amdgcn_target "amdgcn-amd-amdpal--gfx1150"
    .text
    .globl  textured_quad_vs
    .p2align 8                          // 256-byte align (PGM_LO requirement)
    .type   textured_quad_vs,@function

textured_quad_vs:
    // v0 = VertexID
    // Build mask: v1 = vid & 1   (x / u selector)
    //             v2 = vid & 2   (y / v selector, shifted later)
    v_and_b32_e32   v1, 1, v0
    v_and_b32_e32   v2, 2, v0

    // x = (v1 != 0) ? +1.0 : -1.0
    v_cmp_eq_u32_e32 vcc_lo, 0, v1
    v_cndmask_b32_e32 v10, 1.0, -1.0, vcc_lo   // pos.x

    // y = (v2 != 0) ? +1.0 : -1.0
    v_cmp_eq_u32_e32 vcc_lo, 0, v2
    v_cndmask_b32_e32 v11, 1.0, -1.0, vcc_lo   // pos.y

    // z = 0.0, w = 1.0
    v_mov_b32_e32   v12, 0
    v_mov_b32_e32   v13, 1.0

    // u = (v1 != 0) ? 1.0 : 0.0
    v_cmp_ne_u32_e32 vcc_lo, 0, v1
    v_cndmask_b32_e32 v14, 0, 1.0, vcc_lo      // uv.u

    // v = (v2 != 0) ? 0.0 : 1.0   (flip Y so vid=2 lands at top)
    v_cmp_ne_u32_e32 vcc_lo, 0, v2
    v_cndmask_b32_e32 v15, 1.0, 0, vcc_lo      // uv.v

    // Export position (slot 0). On gfx11 exports go through
    // exp mrt/pos/param targets — pos0 = 12.
    //   exp pos0 v10,v11,v12,v13 done
    exp     pos0, v10, v11, v12, v13 done

    // Export parameter 0 (uv). param0 = 32.
    //   exp param0 v14,v15, off, off
    exp     param0, v14, v15, off, off

    s_endpgm

    .size   textured_quad_vs, .-textured_quad_vs

// ----------------------------------------------------------------------------
// Notes for future maintainers
//
// * gfx11 retired LDS-based parameter passing; PS reads exported params via
//   LDS_PARAM_LOAD, but the export side is unchanged from gfx10.
// * If ENABLE_VTX_ID gets disabled in SPI_PS_INPUT_ENA / SPI_VS_OUT_CONFIG
//   the v0 input above will be undefined — keep the PM4 program in sync.
// * Number of VGPRs used here: up to v15. Reflect in
//   SPI_SHADER_PGM_RSRC1_VS.VGPRS = ceil((max_vgpr+1)/4) - 1.
// * Number of SGPRs used: 0 user + vcc only. RSRC1.SGPRS = 0.
// ----------------------------------------------------------------------------
