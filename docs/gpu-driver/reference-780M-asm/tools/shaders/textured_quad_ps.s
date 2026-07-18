// ============================================================================
// textured_quad_ps.s — GFX11 (gfx1150, Strix Point) pixel shader
// ----------------------------------------------------------------------------
// Pairs with textured_quad_vs.s. Samples a 2D texture at the interpolated
// UV exported as param0 by the VS and writes RGBA to MRT0.
//
// Hardware ABI assumed:
//   User SGPRs (programmed via SPI_SHADER_USER_DATA_PS_*):
//     s0..s7  = T# resource descriptor for the texture (8 SGPRs / 256 bits)
//     s8..s11 = S# sampler descriptor              (4 SGPRs / 128 bits)
//   VGPRs in (SPI_PS_INPUT_*):
//     v0..v1 = barycentric coords (i,j) — set ENABLE_PERSP_CENTER_ENA
//     LDS param load reads param0 (u,v) interpolated by the SPI.
//
// On gfx11, parameter inputs are NOT pre-interpolated into VGPRs by the
// SPI; the PS issues `lds_param_load` then `v_interp_p10_f32 /
// v_interp_p2_f32` to interpolate. We use the simpler `v_interp` form
// here for readability.
//
// Build: see textured_quad_vs.s header — same flow.
// ============================================================================

    .amdgcn_target "amdgcn-amd-amdpal--gfx1150"
    .text
    .globl  textured_quad_ps
    .p2align 8
    .type   textured_quad_ps,@function

textured_quad_ps:
    // Load interpolated param0 attributes (u into v2, v into v3).
    // gfx11 uses lds_param_load with an attribute index + channel.
    //   lds_param_load dst, attr_index, channel, m0
    // We pre-set m0 to the param-load setup value via S_MOV; in real
    // drivers this comes from SPI configuration.
    lds_param_load  v2, attr0.x, m0
    lds_param_load  v3, attr0.y, m0
    s_waitcnt       expcnt(0) lgkmcnt(0)

    // Interpolate (P10 + P2). v0=i, v1=j barycentrics.
    v_interp_p10_f32 v4, v2, v0, v2 wait_exp:0       // u: p10
    v_interp_p2_f32  v4, v3, v1, v4                  // u: p2
    v_interp_p10_f32 v5, v2, v0, v2                  // (placeholder for v)
    v_interp_p2_f32  v5, v3, v1, v5
    s_waitcnt       expcnt(0)

    // Sample the texture. image_sample takes:
    //   dst vgprs (4 for RGBA), src vgprs (u,v), T#, S#
    //   dmask:0xF = all four channels
    image_sample    v[6:9], [v4, v5], s[0:7], s[8:11] dmask:0xf dim:SQ_RSRC_IMG_2D
    s_waitcnt       vmcnt(0)

    // Export to MRT0 (color target 0). gfx11 export target for MRT0 = 0.
    exp     mrt0, v6, v7, v8, v9 done compr:0

    s_endpgm

    .size   textured_quad_ps, .-textured_quad_ps

// ----------------------------------------------------------------------------
// Notes
//
// * VGPRs used: up to v9.
//   SPI_SHADER_PGM_RSRC1_PS.VGPRS = ceil((9+1)/4) - 1 = 2.
// * SGPRs used: s0..s11. RSRC1.SGPRS = ceil((11+1)/8) - 1 = 0  (round up to 8).
// * SPI_PS_INPUT_ADDR must include PERSP_CENTER_ENA so v0/v1 carry barys.
// * SPI_PS_INPUT_CNTL_0 must point param0 -> attribute 0.
// * The `dim:SQ_RSRC_IMG_2D` attribute requires recent LLVM (>= 17).
//   Older toolchains use the raw instruction form; document via build_shaders.ps1.
// ----------------------------------------------------------------------------
