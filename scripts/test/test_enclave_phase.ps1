# ============================================================================
# test_enclave_phase.ps1 - Track 10 USB-FPGA enclave one-shot CI guard.
#
# Layers, all fail-closed (any failed assertion exits non-zero):
#   1. SOFTWARE MODELS (via the production GHL compiler) - reference semantics:
#      - enclave_phase.ghl   : the privileged one-shot / latch.
#      - enclave_session.ghl : the authenticated+encrypted session channel
#        (mutual attestation, channel+boot binding, per-frame AEAD nonce).
#      - enclave_boot.ghl    : the Phase-A secure-boot transaction (phase +
#        session composed: sealed-policy judgement, measurement-bound key
#        release, downgrade resistance, fail-closed halt, one-shot lockdown).
#   2. GATEWARE        (src/enclave/rtl/*, synthesizable Amaranth HDL,
#      cycle-simulated) - proves the FPGA logic implements the SAME one-shot:
#      triplicated sticky latch, single-use priv ops, four auto-close triggers,
#      the SecureRAM master-export firewall, and a KDF output matching an
#      independent reference. Then elaborates the design to an RTLIL/Verilog
#      netlist so synthesizability is checked too.
#
# CI stand-in for the board (QEMU/TCG can't model the FPGA); full
# timing-side-channel + tamper validation still needs the HW rig.
#   -SkipGateware : run only the software model (no Amaranth dependency).
# ============================================================================
param([switch]$SkipGateware)
$ErrorActionPreference = 'Stop'

python (Join-Path $PSScriptRoot 'eval_enclave.py')
if ($LASTEXITCODE -ne 0) { Write-Error "enclave phase-machine MODEL FAILED ($LASTEXITCODE)"; exit 1 }

# Authenticated session channel (the USB-MITM hole): mutual attestation,
# channel+boot binding, per-frame AEAD replay/reorder/inject rejection.
python (Join-Path $PSScriptRoot 'eval_enclave_session.py')
if ($LASTEXITCODE -ne 0) { Write-Error "enclave session-channel MODEL FAILED ($LASTEXITCODE)"; exit 1 }

# Phase-A secure-boot transaction (phase+session+boot composed): board-sealed
# policy, measurement-bound key release, downgrade resistance, fail-closed halt.
python (Join-Path $PSScriptRoot 'eval_enclave_boot.py')
if ($LASTEXITCODE -ne 0) { Write-Error "enclave secure-boot transaction MODEL FAILED ($LASTEXITCODE)"; exit 1 }

python (Join-Path $PSScriptRoot 'eval_enclave_usb.py')
if ($LASTEXITCODE -ne 0) { Write-Error "enclave USB protocol MODEL FAILED ($LASTEXITCODE)"; exit 1 }
python (Join-Path $PSScriptRoot 'eval_enclave_supply_chain.py')
if ($LASTEXITCODE -ne 0) { Write-Error "enclave bitstream supply-chain policy FAILED ($LASTEXITCODE)"; exit 1 }
python (Join-Path $PSScriptRoot 'eval_enclave_bootstrap.py')
if ($LASTEXITCODE -ne 0) { Write-Error "enclave Tier-B bootstrap MODEL FAILED ($LASTEXITCODE)"; exit 1 }
python (Join-Path $PSScriptRoot 'eval_enclave_provisioning.py')
if ($LASTEXITCODE -ne 0) { Write-Error "enclave provisioning/revocation MODEL FAILED ($LASTEXITCODE)"; exit 1 }
python (Join-Path $PSScriptRoot 'eval_enclave_hardware_policy.py')
if ($LASTEXITCODE -ne 0) { Write-Error "enclave hardware policy MODEL FAILED ($LASTEXITCODE)"; exit 1 }

# Host integration: atomic Phase-A handoff, monitor/IOMMU exclusive ownership,
# CAP_ENCLAVE default-deny broker, async Phase-B-only API and hot-unplug policy.
python (Join-Path $PSScriptRoot 'eval_enclave_host.py')
if ($LASTEXITCODE -ne 0) { Write-Error "enclave host integration MODEL FAILED ($LASTEXITCODE)"; exit 1 }

if (-not $SkipGateware) {
    python (Join-Path $PSScriptRoot 'eval_enclave_rtl.py')
    if ($LASTEXITCODE -ne 0) { Write-Error "enclave GATEWARE RTL FAILED ($LASTEXITCODE)"; exit 1 }

    python (Join-Path $PSScriptRoot 'eval_enclave_rtl_structure.py')
    if ($LASTEXITCODE -ne 0) { Write-Error "enclave secret-independent RTL STRUCTURE FAILED ($LASTEXITCODE)"; exit 1 }

    python (Join-Path $PSScriptRoot 'eval_enclave_sha512.py')
    if ($LASTEXITCODE -ne 0) { Write-Error "enclave SHA-512 crypto core FAILED ($LASTEXITCODE)"; exit 1 }

    Push-Location (Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'src')
    try { python -m enclave.rtl.generate | Out-Host }
    finally { Pop-Location }
    if ($LASTEXITCODE -ne 0) { Write-Error "enclave netlist generation FAILED ($LASTEXITCODE)"; exit 1 }
}

Write-Host "[test_enclave_phase] Track 10 P0: model + gateware one-shot all enforced" -ForegroundColor Green
