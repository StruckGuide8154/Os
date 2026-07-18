import copy
import importlib.util
import struct
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MODULE_SPEC = importlib.util.spec_from_file_location("theme_tool", ROOT / "tools" / "theme_tool.py")
theme_tool = importlib.util.module_from_spec(MODULE_SPEC)
assert MODULE_SPEC.loader is not None
MODULE_SPEC.loader.exec_module(theme_tool)


class ThemeToolTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.spec, cls.canonical = theme_tool.load_spec()

    def test_repository_spec_is_valid(self):
        theme_tool.validate_spec(self.spec)

    def test_missing_token_is_rejected(self):
        broken = copy.deepcopy(self.spec)
        del broken["themes"]["light"]["colors"]["taskbar_bg"]
        with self.assertRaisesRegex(theme_tool.ThemeError, "token mismatch"):
            theme_tool.validate_spec(broken)

    def test_noncanonical_color_is_rejected(self):
        broken = copy.deepcopy(self.spec)
        broken["themes"]["light"]["colors"]["accent"] = "#9a7637"
        with self.assertRaisesRegex(theme_tool.ThemeError, "uppercase"):
            theme_tool.validate_spec(broken)

    def test_low_contrast_is_rejected(self):
        broken = copy.deepcopy(self.spec)
        broken["themes"]["light"]["colors"]["text"] = broken["themes"]["light"]["colors"]["bg_base"]
        with self.assertRaisesRegex(theme_tool.ThemeError, "contrast"):
            theme_tool.validate_spec(broken)

    def test_npl_layout_is_bounded_and_ordered(self):
        blob = theme_tool._npl(self.spec, "light")
        magic, count, channels, reserved = struct.unpack("<4sHBB", blob[:8])
        self.assertEqual(magic, b"NPL1")
        self.assertEqual(count, len(self.spec["tokens"]))
        self.assertEqual(channels, 3)
        self.assertEqual(reserved, 0)
        self.assertEqual(len(blob), 8 + count * channels)
        self.assertEqual(blob[8:11], bytes.fromhex(self.spec["themes"]["light"]["colors"]["bg_base"][1:]))

    def test_text_output_check_accepts_crlf(self):
        self.assertTrue(
            theme_tool._output_matches(theme_tool.CONSTANTS_PATH, b"one\r\ntwo\r\n", b"one\ntwo\n")
        )

    def test_binary_output_check_remains_byte_exact(self):
        palette = ROOT / "assets" / "themes" / "light" / "palette.npl"
        self.assertFalse(theme_tool._output_matches(palette, b"one\r\ntwo", b"one\ntwo"))


if __name__ == "__main__":
    unittest.main()
