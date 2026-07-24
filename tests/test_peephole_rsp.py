"""Regression tests for the GritHL peephole optimizer's operand-relocation
safety (src/user/grithl/compiler/gritc.py).

The peephole's Pass A collapses the naive stack machine's
`(mov rax, OP ; push rax){N} (pop REG){N}` argument-staging idiom into direct
`mov REG, OP` moves. That rewrite DELETES the `push`/`pop` pairs, so any staged
source operand must be position-independent with respect to rsp. An
`rsp`-relative source is NOT: the first `push` displaces rsp, so
`mov rax, [rsp+K]` at stage i>0 reads a different stack word than the same text
would read after the pushes are gone.

_operand_safe_for_target used to treat `rsp` as relocatable (it was on the
allowlist and the fall-through denylist did not catch it), so the "lossless"
peephole silently miscompiled any rsp-relative staging. This pass runs on the
kernel target at -O0, so the bug reached ring 0. These tests pin the fix.
"""

import importlib.util
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
_SPEC = importlib.util.spec_from_file_location(
    "gritc", ROOT / "src" / "user" / "grithl" / "compiler" / "gritc.py")
gritc = importlib.util.module_from_spec(_SPEC)
assert _SPEC.loader is not None
_SPEC.loader.exec_module(gritc)


class OperandSafetyTests(unittest.TestCase):
    def test_rsp_source_is_not_relocatable(self):
        # Every stack-pointer spelling must be rejected as a relocation source.
        for op in ("[rsp+8]", "[rsp-16]", "[rsp]", "[esp+4]",
                   "qword [rsp+32]"):
            self.assertFalse(
                gritc._operand_safe_for_target(op, "rbx"),
                f"{op!r} must not be treated as safe to relocate")

    def test_rbp_and_immediate_sources_stay_relocatable(self):
        # The fix must not over-reject the operands the pass legitimately moves.
        for op in ("[rbp-8]", "[rbp+16]", "42", "0x1000", "[rel some_label]"):
            self.assertTrue(
                gritc._operand_safe_for_target(op, "rbx"),
                f"{op!r} should remain safe to relocate")


class PeepholeRewriteTests(unittest.TestCase):
    def test_rsp_staging_is_not_collapsed_to_wrong_slots(self):
        # Two rsp-relative loads staged across a displacing push. Collapsing them
        # into two `mov REG, [rsp+8]` would make both read the SAME word, but the
        # first push means the second staged load reads a DIFFERENT word. The
        # pass must not produce two identical rsp-relative loads.
        seq = [
            "    mov rax, [rsp+8]",
            "    push rax",
            "    mov rax, [rsp+8]",
            "    push rax",
            "    pop rbx",
            "    pop rcx",
        ]
        # extended=False mirrors the kernel's -O0 build, where this pass runs.
        out = gritc._peephole(list(seq), extended=False, zero_idiom=False)
        text = "\n".join(gritc._code(l).strip() for l in out)
        # The tell-tale miscompile is the two collapsed, identical rsp loads.
        self.assertNotIn("mov rbx, [rsp+8]", text)
        self.assertNotIn("mov rcx, [rsp+8]", text)

    def test_immediate_staging_is_still_collapsed(self):
        # Guard against an over-broad fix: immediate/rbp staging must still fold
        # (this is the optimization the pass exists for).
        seq = [
            "    mov rax, 10",
            "    push rax",
            "    mov rax, [rbp-8]",
            "    push rax",
            "    pop rbx",
            "    pop rcx",
        ]
        out = gritc._peephole(list(seq), extended=False, zero_idiom=False)
        text = "\n".join(gritc._code(l).strip() for l in out)
        self.assertNotIn("push rax", text)   # staging fully collapsed
        self.assertIn("mov rbx, [rbp-8]", text)
        self.assertIn("mov rcx, 10", text)


if __name__ == "__main__":
    unittest.main()
