#!/usr/bin/env bash
# ============================================================================
# fetch_phoenix_fw.sh — pull Phoenix (Ryzen 780M, gfx_11_0_3) firmware blobs
#                      from a Linux box's /lib/firmware/amdgpu/, rename to
#                      the 8.3 PHX*.BIN aliases GritOS expects, and place
#                      them in assets/firmware/.
#
# Run on a Linux machine that has:
#   * an AMD driver-using kernel (so amdgpu firmware is installed), OR
#   * the linux-firmware git repo checked out and pointed at via env var
#     LINUX_FIRMWARE_DIR.
#
# Usage:
#   tools/gpu/fetch_phoenix_fw.sh           # from this repo root
#   LINUX_FIRMWARE_DIR=~/src/linux-firmware tools/gpu/fetch_phoenix_fw.sh
#
# Output:
#   assets/firmware/PHXPFP.BIN
#   assets/firmware/PHXME.BIN
#   assets/firmware/PHXMEC.BIN
#   assets/firmware/PHXRLC.BIN
#   assets/firmware/PHXIMU.BIN
#   assets/firmware/PHXMES.BIN
#   assets/firmware/PHXSDMA.BIN
#   assets/firmware/PHXSOS.BIN     (psp_13_0_5 sos)
#   assets/firmware/PHXASD.BIN     (psp_13_0_5 asd)
#   assets/firmware/PHXTA.BIN      (psp_13_0_5 ta)
#   assets/firmware/PHXTOC.BIN     (psp_13_0_5 toc)
#
# The mapping is the single source of truth — keep it in sync with
# src/kernel/drivers/gpu/amd_imu.asm::fw_name_table.
# ============================================================================
set -euo pipefail

# Locate this repo root by walking up from the script.
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd "$SCRIPT_DIR/../.." && pwd)
DEST="$REPO_ROOT/assets/firmware"
mkdir -p "$DEST"

# Source dir: env override, then /lib/firmware, then likely linux-firmware paths.
SRC="${LINUX_FIRMWARE_DIR:-}"
if [ -z "$SRC" ]; then
    for candidate in /lib/firmware/amdgpu /usr/lib/firmware/amdgpu \
                     "$HOME/src/linux-firmware/amdgpu" \
                     "$HOME/linux-firmware/amdgpu"; do
        if [ -d "$candidate" ]; then
            SRC="$candidate"
            break
        fi
    done
fi
if [ -z "$SRC" ] || [ ! -d "$SRC" ]; then
    echo "error: could not locate amdgpu firmware directory."
    echo "       set LINUX_FIRMWARE_DIR=/path/to/linux-firmware/amdgpu"
    echo "       or install amdgpu firmware on this machine."
    exit 1
fi
# Strip trailing /amdgpu if user pointed at the root linux-firmware dir.
if [ ! -f "$SRC/gc_11_0_3_pfp.bin" ] && [ -f "$SRC/amdgpu/gc_11_0_3_pfp.bin" ]; then
    SRC="$SRC/amdgpu"
fi

echo "  source: $SRC"
echo "  dest:   $DEST"
echo

# Mapping: "<src_basename> <PHX*.BIN>"
# Order matches fw_name_table in amd_imu.asm (PFP, ME, MEC, RLC, IMU, MES,
# SDMA, then PSP bootloader pieces).
declare -a MAP=(
    "gc_11_0_3_pfp.bin       PHXPFP.BIN"
    "gc_11_0_3_me.bin        PHXME.BIN"
    "gc_11_0_3_mec.bin       PHXMEC.BIN"
    "gc_11_0_3_rlc.bin       PHXRLC.BIN"
    "gc_11_0_3_imu.bin       PHXIMU.BIN"
    "gc_11_0_3_mes_2.bin     PHXMES.BIN"
    "sdma_6_0_2.bin          PHXSDMA.BIN"
    "psp_13_0_5_sos.bin      PHXSOS.BIN"
    "psp_13_0_5_asd.bin      PHXASD.BIN"
    "psp_13_0_5_ta.bin       PHXTA.BIN"
    "psp_13_0_5_toc.bin      PHXTOC.BIN"
)

missing=0
copied=0
for entry in "${MAP[@]}"; do
    read -r src_name dst_name <<<"$entry"
    src_path="$SRC/$src_name"
    dst_path="$DEST/$dst_name"
    if [ ! -f "$src_path" ]; then
        echo "  MISS  $src_name"
        missing=$((missing + 1))
        continue
    fi
    cp -f "$src_path" "$dst_path"
    size=$(stat -c %s "$dst_path" 2>/dev/null || stat -f %z "$dst_path")
    printf "  OK    %-25s -> %-12s (%d bytes)\n" "$src_name" "$dst_name" "$size"
    copied=$((copied + 1))
done

echo
echo "  copied: $copied"
echo "  missing: $missing"
if [ "$missing" -gt 0 ]; then
    echo
    echo "  Some blobs were not present. If this Linux box doesn't have the"
    echo "  full Phoenix amdgpu firmware set installed, clone linux-firmware:"
    echo "    git clone --depth 1 \\"
    echo "      https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git"
    echo "    LINUX_FIRMWARE_DIR=./linux-firmware/amdgpu $0"
    exit 2
fi

# Sanity probe: first 16 bytes of each blob should look like an AMD signed
# firmware header. The header magic is at offset 0x10 typically; quick check
# is just that the file isn't 0-length and starts with non-zero bytes.
echo
echo "  Sanity probe (first 16 bytes per blob):"
for entry in "${MAP[@]}"; do
    read -r _ dst_name <<<"$entry"
    dst_path="$DEST/$dst_name"
    [ -f "$dst_path" ] || continue
    head_hex=$(xxd -l 16 -p "$dst_path" | tr -d '\n')
    printf "    %-12s %s\n" "$dst_name" "$head_hex"
done

echo
echo "  Done. Rebuild GritOS with -Gfx and the FAT16 image will pick these up."
