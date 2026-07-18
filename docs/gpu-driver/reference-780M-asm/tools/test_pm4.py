"""
Unit tests for tools/gpu/pm4.py.

Verifies bit layouts against the AMD PM4 type-3 spec. Run with:

    python -m unittest tools.gpu.test_pm4

or directly:

    python tools/gpu/test_pm4.py
"""

from __future__ import annotations

import os
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import pm4  # noqa: E402


class HeaderTests(unittest.TestCase):
    def test_nop_header_single_body(self):
        # NOP, 1 body dword -> count field = 0
        h = pm4.pm4_type3_header(pm4.IT_NOP, body_dwords=1)
        # type=3 in top 2 bits, opcode 0x10 in bits 15:8, rest zero
        self.assertEqual(h, (3 << 30) | (0x10 << 8))

    def test_count_is_body_minus_one(self):
        h = pm4.pm4_type3_header(pm4.IT_SET_SH_REG, body_dwords=4)
        # count = 3
        self.assertEqual((h >> 16) & 0x3FFF, 3)
        self.assertEqual((h >> 8) & 0xFF, pm4.IT_SET_SH_REG)
        self.assertEqual(h >> 30, 3)

    def test_shader_type_bit(self):
        h = pm4.pm4_type3_header(pm4.IT_SET_SH_REG, 2,
                                 shader_type=pm4.SHADER_TYPE_COMPUTE)
        self.assertEqual(h & 1, 1)

    def test_rejects_zero_body(self):
        with self.assertRaises(ValueError):
            pm4.pm4_type3_header(pm4.IT_NOP, 0)

    def test_rejects_oversize(self):
        with self.assertRaises(ValueError):
            pm4.pm4_type3_header(pm4.IT_NOP, 0x4001)


class BuilderTests(unittest.TestCase):
    def test_nop_packet_bytes(self):
        b = pm4.PM4Builder()
        b.nop(pad_dwords=2)
        dws = b.dwords()
        # header + 2 zero dwords
        self.assertEqual(len(dws), 3)
        self.assertEqual(dws[0],
                         pm4.pm4_type3_header(pm4.IT_NOP, body_dwords=2))
        self.assertEqual(dws[1], 0)
        self.assertEqual(dws[2], 0)

    def test_set_sh_reg_offset_math(self):
        # SPI_SHADER_PGM_LO_VS (gfx10/11) is at 0x2C4C dword offset
        # => absolute byte offset 0x2C4C << 2 = 0xB130
        b = pm4.PM4Builder()
        b.set_sh_reg(0x2C4C << 2, [0xDEADBEEF, 0x00000001])
        dws = b.dwords()
        # header + reg_dw + 2 values
        self.assertEqual(len(dws), 4)
        # body dwords = 3 -> count field = 2
        self.assertEqual((dws[0] >> 16) & 0x3FFF, 2)
        self.assertEqual((dws[0] >> 8) & 0xFF, pm4.IT_SET_SH_REG)
        # reg_dw = (offset/4) - BASE_SH = 0x2C4C - 0x2C00 = 0x4C
        self.assertEqual(dws[1], 0x4C)
        self.assertEqual(dws[2], 0xDEADBEEF)
        self.assertEqual(dws[3], 1)

    def test_set_context_reg_rejects_out_of_window(self):
        b = pm4.PM4Builder()
        # SH register handed to context API -> negative offset
        with self.assertRaises(ValueError):
            b.set_context_reg(0x2C4C << 2, [0])

    def test_draw_index_auto(self):
        b = pm4.PM4Builder()
        b.draw_index_auto(index_count=6, draw_initiator=0x2)
        dws = b.dwords()
        self.assertEqual(len(dws), 3)
        self.assertEqual((dws[0] >> 8) & 0xFF, pm4.IT_DRAW_INDEX_AUTO)
        # body dwords = 2 -> count = 1
        self.assertEqual((dws[0] >> 16) & 0x3FFF, 1)
        self.assertEqual(dws[1], 6)
        self.assertEqual(dws[2], 0x2)

    def test_event_write(self):
        b = pm4.PM4Builder()
        b.event_write(pm4.EVENT_VS_PARTIAL_FLUSH,
                      event_index=pm4.EVENT_INDEX_PARTIAL)
        dws = b.dwords()
        self.assertEqual(len(dws), 2)
        self.assertEqual((dws[0] >> 8) & 0xFF, pm4.IT_EVENT_WRITE)
        self.assertEqual(dws[1] & 0x3F, pm4.EVENT_VS_PARTIAL_FLUSH)
        self.assertEqual((dws[1] >> 8) & 0xF, pm4.EVENT_INDEX_PARTIAL)

    def test_wait_reg_mem_register_space(self):
        b = pm4.PM4Builder()
        # poll CP_HQD_ACTIVE (made-up byte offset) until EQ 1
        b.wait_reg_mem(mem_space=pm4.WAIT_SPACE_REG,
                       function=pm4.WAIT_FUNC_EQ,
                       poll_addr=0x8AB0,  # byte offset
                       reference=1, mask=1, poll_interval=4)
        dws = b.dwords()
        self.assertEqual(len(dws), 7)
        self.assertEqual((dws[0] >> 8) & 0xFF, pm4.IT_WAIT_REG_MEM)
        # body dwords = 6 -> count = 5
        self.assertEqual((dws[0] >> 16) & 0x3FFF, 5)
        # function bits 2:0 == EQ (3), mem_space bit 4 == 0
        self.assertEqual(dws[1] & 0x7, pm4.WAIT_FUNC_EQ)
        self.assertEqual((dws[1] >> 4) & 0x1, 0)
        # poll_addr_lo holds dword index (byte offset >> 2)
        self.assertEqual(dws[2], 0x8AB0 >> 2)
        self.assertEqual(dws[3], 0)
        self.assertEqual(dws[4], 1)
        self.assertEqual(dws[5], 1)
        self.assertEqual(dws[6], 4)

    def test_wait_reg_mem_memory_space_64bit(self):
        b = pm4.PM4Builder()
        addr = 0x1_2345_6789_ABCD_0000
        b.wait_reg_mem(mem_space=pm4.WAIT_SPACE_MEM,
                       function=pm4.WAIT_FUNC_GE,
                       poll_addr=addr,
                       reference=0xAAAA, mask=0xFFFF,
                       poll_interval=0x10)
        dws = b.dwords()
        self.assertEqual((dws[1] >> 4) & 0x1, 1)
        self.assertEqual(dws[2], addr & 0xFFFFFFFF)
        self.assertEqual(dws[3], (addr >> 32) & 0xFFFFFFFF)

    def test_buffer_is_little_endian(self):
        b = pm4.PM4Builder()
        b.emit_dw(0x11223344)
        self.assertEqual(bytes(b), b"\x44\x33\x22\x11")


if __name__ == "__main__":
    unittest.main()
