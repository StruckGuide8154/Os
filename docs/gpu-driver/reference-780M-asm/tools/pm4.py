"""
PM4 packet builder for AMD GFX11 (Strix Point, GC 11.5).

Pure-Python, no dependencies. Emits raw little-endian DWORDs into a
bytearray and exposes a small, opcode-table-driven API so future
opcodes can be added without touching control flow.

Conventions
-----------
PM4 type-3 header layout (AMD ROCm / Linux drm/amd/include/pm4):

    bits 31:30  type   (always 0b11 = 3 for type-3)
    bits 29:16  count  (number of DWORDs that FOLLOW the header,
                        minus 1; i.e. body_dwords - 1)
    bits 15:8   opcode (IT_* below)
    bits 7:1    reserved (0)
    bit  0      shader_type (0 = graphics, 1 = compute)

SET_*_REG packets carry a *register offset* in their first body DWORD,
expressed as ``(absolute_reg_offset - base) >> 2`` where ``base``
depends on the variant (context / sh / uconfig / config).

This module is intentionally read-only with respect to hardware. It
builds buffers; submitting them to a CP ring is a separate concern.
"""

from __future__ import annotations

import struct
from dataclasses import dataclass, field
from typing import Iterable, Sequence


# ---------------------------------------------------------------------------
# Opcode table - IT_* names mirror AMD/Linux for grep-ability.
# Source: drivers/gpu/drm/amd/amdgpu/soc15d.h, sid.h, pm4_header.h
# ---------------------------------------------------------------------------

IT_NOP                = 0x10
IT_SET_BASE           = 0x11
IT_INDEX_BUFFER_SIZE  = 0x2A
IT_DRAW_INDEX_AUTO    = 0x2D
IT_NUM_INSTANCES      = 0x2F
IT_INDIRECT_BUFFER    = 0x3F
IT_WAIT_REG_MEM       = 0x3C
IT_MEM_SEMAPHORE      = 0x39
IT_EVENT_WRITE        = 0x46
IT_EVENT_WRITE_EOP    = 0x47
IT_RELEASE_MEM        = 0x49
IT_ACQUIRE_MEM        = 0x58
IT_SET_CONTEXT_REG    = 0x69
IT_SET_SH_REG         = 0x76
IT_SET_UCONFIG_REG    = 0x79
IT_SET_CONFIG_REG     = 0x68


# Register-window bases. A SET_*_REG packet stores
#   reg_dword_offset = (absolute_byte_offset / 4) - base_dword
# in its first body dword. These bases are stable across GFX10/11.
BASE_CONTEXT  = 0xA000
BASE_SH       = 0x2C00
BASE_UCONFIG  = 0xC000
BASE_CONFIG   = 0x2000


# WAIT_REG_MEM "function" field (3-bit). Linux: WAIT_REG_MEM_FUNCTION_*
WAIT_FUNC_ALWAYS = 0
WAIT_FUNC_LT     = 1
WAIT_FUNC_LE     = 2
WAIT_FUNC_EQ     = 3
WAIT_FUNC_NE     = 4
WAIT_FUNC_GE     = 5
WAIT_FUNC_GT     = 6

# WAIT_REG_MEM "mem_space"
WAIT_SPACE_REG = 0
WAIT_SPACE_MEM = 1

# EVENT_WRITE "event_type" - small subset; extend as needed.
EVENT_CACHE_FLUSH         = 0x04
EVENT_CACHE_FLUSH_TS      = 0x14
EVENT_VS_PARTIAL_FLUSH    = 0x0F
EVENT_PS_PARTIAL_FLUSH    = 0x10
EVENT_PIPELINESTAT_START  = 0x19
EVENT_PIPELINESTAT_STOP   = 0x1A
EVENT_BOTTOM_OF_PIPE_TS   = 0x28

# EVENT_WRITE "event_index" (4-bit).
EVENT_INDEX_OTHER    = 0
EVENT_INDEX_ZPASS    = 1
EVENT_INDEX_SAMPLE   = 2
EVENT_INDEX_PARTIAL  = 4
EVENT_INDEX_TS       = 5


SHADER_TYPE_GFX     = 0
SHADER_TYPE_COMPUTE = 1


def pm4_type3_header(opcode: int, body_dwords: int,
                     shader_type: int = SHADER_TYPE_GFX) -> int:
    """Build a PM4 type-3 header.

    ``body_dwords`` is the number of DWORDs that follow the header
    (NOT including the header itself). Must be >= 1.
    """
    if body_dwords < 1:
        raise ValueError("PM4 type-3 packets need at least 1 body dword "
                         f"(opcode {opcode:#x})")
    if not 0 <= opcode <= 0xFF:
        raise ValueError(f"opcode out of range: {opcode:#x}")
    if shader_type not in (0, 1):
        raise ValueError(f"bad shader_type: {shader_type}")
    count = body_dwords - 1
    if count > 0x3FFF:
        raise ValueError(f"packet too large: body_dwords={body_dwords}")
    return ((3 & 0x3) << 30) | ((count & 0x3FFF) << 16) \
         | ((opcode & 0xFF) << 8) | (shader_type & 1)


# ---------------------------------------------------------------------------
# Builder
# ---------------------------------------------------------------------------

@dataclass
class PM4Builder:
    """Accumulates PM4 dwords into an internal bytearray.

    All values are emitted little-endian (PM4 is LE on all AMD GPUs).
    The builder never reads hardware; ``bytes()`` returns the buffer
    ready for upload into a CP indirect-buffer or ring.
    """
    buf: bytearray = field(default_factory=bytearray)

    # --- raw plumbing ---------------------------------------------------
    def emit_dw(self, dw: int) -> None:
        self.buf += struct.pack("<I", dw & 0xFFFFFFFF)

    def emit_dws(self, dws: Iterable[int]) -> None:
        for dw in dws:
            self.emit_dw(dw)

    def emit_qw(self, qw: int) -> None:
        """Emit a 64-bit value as two LE dwords (lo, hi)."""
        self.emit_dw(qw & 0xFFFFFFFF)
        self.emit_dw((qw >> 32) & 0xFFFFFFFF)

    def __len__(self) -> int:
        return len(self.buf)

    def __bytes__(self) -> bytes:
        return bytes(self.buf)

    def dwords(self) -> list[int]:
        """Return the buffer as a list of LE dwords (for tests)."""
        n = len(self.buf) // 4
        return list(struct.unpack(f"<{n}I", bytes(self.buf)))

    # --- packets --------------------------------------------------------
    def nop(self, pad_dwords: int = 1) -> None:
        """Emit a NOP whose body is ``pad_dwords`` zero DWORDs.

        The CP treats the entire packet as a no-op; we use NOP as
        padding for alignment or as a "filler" between live packets.
        """
        if pad_dwords < 1:
            raise ValueError("nop pad_dwords must be >= 1")
        self.emit_dw(pm4_type3_header(IT_NOP, pad_dwords))
        for _ in range(pad_dwords):
            self.emit_dw(0)

    def _set_regs(self, opcode: int, base: int, reg_offset: int,
                  values: Sequence[int]) -> None:
        if not values:
            raise ValueError("SET_*_REG requires at least one value")
        reg_dw = (reg_offset >> 2) - base
        if reg_dw < 0 or reg_dw > 0xFFFF:
            raise ValueError(
                f"reg offset {reg_offset:#x} out of window for base "
                f"{base:#x} (got reg_dw={reg_dw})")
        body = 1 + len(values)  # reg index dword + N value dwords
        self.emit_dw(pm4_type3_header(opcode, body))
        self.emit_dw(reg_dw)
        self.emit_dws(values)

    def set_context_reg(self, reg_offset: int,
                        values: int | Sequence[int]) -> None:
        if isinstance(values, int):
            values = (values,)
        self._set_regs(IT_SET_CONTEXT_REG, BASE_CONTEXT, reg_offset, values)

    def set_sh_reg(self, reg_offset: int,
                   values: int | Sequence[int]) -> None:
        if isinstance(values, int):
            values = (values,)
        self._set_regs(IT_SET_SH_REG, BASE_SH, reg_offset, values)

    def set_uconfig_reg(self, reg_offset: int,
                        values: int | Sequence[int]) -> None:
        if isinstance(values, int):
            values = (values,)
        self._set_regs(IT_SET_UCONFIG_REG, BASE_UCONFIG, reg_offset, values)

    def set_config_reg(self, reg_offset: int,
                       values: int | Sequence[int]) -> None:
        if isinstance(values, int):
            values = (values,)
        self._set_regs(IT_SET_CONFIG_REG, BASE_CONFIG, reg_offset, values)

    def draw_index_auto(self, index_count: int,
                        draw_initiator: int = 0) -> None:
        """DRAW_INDEX_AUTO - non-indexed draw using auto-indices.

        Body: index_count, draw_initiator (VGT_DRAW_INITIATOR).
        """
        if index_count < 0 or index_count > 0xFFFFFFFF:
            raise ValueError(f"index_count out of range: {index_count}")
        self.emit_dw(pm4_type3_header(IT_DRAW_INDEX_AUTO, 2))
        self.emit_dw(index_count)
        self.emit_dw(draw_initiator)

    def event_write(self, event_type: int,
                    event_index: int = EVENT_INDEX_OTHER) -> None:
        """Minimal 2-dword EVENT_WRITE (no address payload).

        For TS / EOP variants that carry an address+value, use
        ``release_mem`` / a dedicated wrapper instead.
        """
        dw1 = (event_type & 0x3F) | ((event_index & 0xF) << 8)
        self.emit_dw(pm4_type3_header(IT_EVENT_WRITE, 1))
        self.emit_dw(dw1)

    def wait_reg_mem(self, *, mem_space: int, function: int,
                     poll_addr: int, reference: int, mask: int,
                     poll_interval: int = 4,
                     engine_sel: int = 0) -> None:
        """WAIT_REG_MEM - poll a register or memory location.

        Body layout (6 dwords):
          DW1: control = function[2:0] | mem_space[4] | engine[8]
          DW2: poll_addr_lo  (reg index if mem_space==REG; byte addr lo if MEM)
          DW3: poll_addr_hi  (0 if REG)
          DW4: reference
          DW5: mask
          DW6: poll_interval
        """
        if function & ~0x7:
            raise ValueError(f"function out of 3-bit range: {function}")
        if mem_space not in (0, 1):
            raise ValueError(f"mem_space must be 0 or 1, got {mem_space}")
        ctrl = (function & 0x7) | ((mem_space & 0x1) << 4) \
             | ((engine_sel & 0x1) << 8)
        if mem_space == WAIT_SPACE_REG:
            addr_lo = (poll_addr >> 2) & 0xFFFFFFFF
            addr_hi = 0
        else:
            addr_lo = poll_addr & 0xFFFFFFFF
            addr_hi = (poll_addr >> 32) & 0xFFFFFFFF
        self.emit_dw(pm4_type3_header(IT_WAIT_REG_MEM, 6))
        self.emit_dw(ctrl)
        self.emit_dw(addr_lo)
        self.emit_dw(addr_hi)
        self.emit_dw(reference & 0xFFFFFFFF)
        self.emit_dw(mask & 0xFFFFFFFF)
        self.emit_dw(poll_interval & 0xFFFFFFFF)


__all__ = [
    # opcodes
    "IT_NOP", "IT_SET_CONTEXT_REG", "IT_SET_SH_REG", "IT_SET_UCONFIG_REG",
    "IT_SET_CONFIG_REG", "IT_DRAW_INDEX_AUTO", "IT_EVENT_WRITE",
    "IT_WAIT_REG_MEM", "IT_RELEASE_MEM", "IT_ACQUIRE_MEM",
    # bases
    "BASE_CONTEXT", "BASE_SH", "BASE_UCONFIG", "BASE_CONFIG",
    # enums
    "WAIT_FUNC_ALWAYS", "WAIT_FUNC_LT", "WAIT_FUNC_LE", "WAIT_FUNC_EQ",
    "WAIT_FUNC_NE", "WAIT_FUNC_GE", "WAIT_FUNC_GT",
    "WAIT_SPACE_REG", "WAIT_SPACE_MEM",
    "EVENT_CACHE_FLUSH", "EVENT_CACHE_FLUSH_TS", "EVENT_VS_PARTIAL_FLUSH",
    "EVENT_PS_PARTIAL_FLUSH", "EVENT_BOTTOM_OF_PIPE_TS",
    "EVENT_INDEX_OTHER", "EVENT_INDEX_TS", "EVENT_INDEX_PARTIAL",
    "SHADER_TYPE_GFX", "SHADER_TYPE_COMPUTE",
    # api
    "pm4_type3_header", "PM4Builder",
]
