# Scripts & tools inventory - what's required vs utility

Single source of truth for "is this script needed?". **Required** = invoked by CI,
the build pipeline, or a verification aggregator (so deleting/breaking it breaks a
build or a gate). **Utility** = manual/dev/debug; nothing automated depends on it.

Physical rule of thumb after the 2026-06-13 tidy-up: anything under a **`dev/`**
directory is utility; everything else is required. (CI-pinned entry points -
`scripts/build`, `scripts/run`, the required `scripts/test` gates - were kept in
place on purpose; relocating them would break the CI contract.)

## REQUIRED - build pipeline
Entry: `scripts/build/build_uefi.ps1` (and `build_bios.ps1`), CI + `test_verify_all`.

| Path | Role |
|---|---|
| `scripts/build/build_uefi.ps1` | UEFI build/release entry (signs ESP, runs the release gate) |
| `scripts/build/build_bios.ps1` | BIOS build entry |
| `scripts/build/build_ghl.ps1` | compile GritHL apps -> build/ghl |
| `scripts/build/build_probe.ps1` | build the security_probe image (used by `check_build_integrity`) |
| `scripts/build/write_envelope.py` | Ed25519 quorum envelope signer (SYSSIG/KERNEL/KUPDATE.ENV) |
| `scripts/build/ed25519_host.py` | host Ed25519 helper for signing/eval |
| `tools/build/extract_apps.ps1` | extract APPS.BIN from the kernel image |
| `tools/build/extract_kaslr_fixups.py` | build KASLR fixup table, wrap KERNEL.BIN |
| `tools/build/gen_app_manifest.py` | per-app integrity manifest (keyless SHA-256 trailer) |
| `tools/build/gen_loader_manifest.py` | pin payload hashes into the signed loader |
| `tools/build/patch_blob_sig.py` | embed the KASLR sliding-fixup table (load-bearing) |
| `tools/build_sig_registry.py` | signature registry (called by `build_ghl.ps1`) |
| `tools/check_coverage.py` | signature coverage gate (called by `build_uefi`) |
| `tools/gen_boot_anim.py`, `tools/gen_wallpaper_strings.py` | build assets |
| `tools/quantum/qrng_seed.py` | QRNG seed generation (private seed stays off-image) |

## REQUIRED - run
| Path | Role |
|---|---|
| `scripts/run/run_uefi.ps1` | boot the UEFI image in QEMU (CI smoke + many tests) |
| `scripts/run/run_bios.ps1` | boot the BIOS image (used by `test_cache32_boot`) |

## REQUIRED - CI security gate
Entry: `.github/workflows/ghl-security.yml` -> `scripts/test/ci_security_summary.ps1`.

| Path | Role |
|---|---|
| `scripts/test/ci_security_summary.ps1` | CI entry; surfaces the signal lines |
| `scripts/test/ci_dirty_output_guard.ps1` | fail if a guard dirtied the tree |
| `scripts/test/test_ghl_security_guards.ps1` | the security guard suite entry |
| `scripts/test/test_enforcement_meta.ps1`, `test_ghl_invariants.ps1`, `test_ghl_security_fixtures.ps1`, `test_no_shipped_secrets.ps1`, `test_forge_resist.ps1`, `test_gritc_security.ps1` | guard members |
| `scripts/test/eval_ed25519.py`, `eval_envelope.py`, `fuzz_envelope.py`, `eval_invariants.py`, `derive_authority.py` | host eval/fuzz harnesses the guards call |
| `tools/security/check_no_asm.ps1`, `check_ghl_presubmit.ps1`, `check_build_integrity.ps1`, `check_release_privacy.ps1`, `check_no_shipped_secrets.ps1`, `check_release_artifacts.py` | security guards |
| `scripts/test/boot_parity.ps1` | boot A/B parity (called by `check_build_integrity`) |
| `scripts/test/test_security_regression.ps1` | ring-3 PoC regression (build `-SecurityRegression`) |

## REQUIRED - verification aggregator + repo checks
Entry: `scripts/test/test_verify_all.ps1`.

| Path | Role |
|---|---|
| `scripts/test/test_source_guards.ps1`, `test_ghl_fixtures.ps1`, `test_smoke_uefi.ps1`, `test_l3_app_markers.ps1`, `test_explorer_app_markers.ps1`, `test_cache32_boot.ps1`, `test_smp_boot.ps1` | boot/marker/fixture validation |
| `tools/check_xml_svg_contracts.ps1`, `check_invariants.ps1`, `check_docs.ps1`, `check_complexity_thresholds.ps1`, `check_ownership.ps1`, `complexity_dashboard.ps1`, `generate_source_map.ps1` | repo-enforcement checks |

## UTILITY (dev/manual) - `scripts/dev/`, `tools/dev/`
Nothing automated depends on these; run by hand when needed.

| Path | Role |
|---|---|
| `scripts/dev/agent2_fbtest.ps1`, `shot.ps1`, `probe_diag.ps1`, `boot_markers.ps1` | ad-hoc boot/framebuffer probes |
| `scripts/dev/test_cpu_profile.ps1`, `test_gui_llc_profile.ps1`, `test_mouse_cursor_move.ps1` | manual perf/interaction harnesses |
| `scripts/dev/test_track2_envelope_callsites.ps1`, `test_track4_planted_leak.ps1`, `test_track4_pmemsave.ps1` | manual Track-2/4 verification |
| `scripts/dev/test_security_probe.ps1` | manual fault-injection harness |
| `scripts/dev/configure_qemu_tap.ps1` | one-time QEMU TAP networking setup |
| `tools/dev/auto_wrap_globals.py`, `split_asm.py`, `trace_replay.py` | one-off source/asm/trace tooling |
| `tools/dev/report_dirty_files.ps1`, `svg_compare.ps1` | dev reporting / SVG render diff |

## DEBUG - `tools/debug/`
All manual debug helpers (serial capture, SDL run, fault hunts, input injection).
Never on an automated path.

## INFRA / research (not build-required)
| Path | Role |
|---|---|
| `tools/agentchat/*` | parallel-agent coordination chatroom |
| `tools/quantum/policy_graph_qaoa.py` | research (QAOA policy-graph experiment) |

## Maintenance rule
When you add a script: if CI / the build / an aggregator calls it, it's **required** -
put it in the matching dir above and list it here. Otherwise it's **utility** - put
it under a `dev/` (or `tools/debug/`) directory. Keep this table current; it is what
makes "what's needed" answerable at a glance.
