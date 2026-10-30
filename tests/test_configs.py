"""Schema checks for every shipped .wsb profile.

Mirrors scripts/Test-SandboxConfig.ps1 so the same rules can be
checked cross-platform (and in CI on the Windows runner, alongside
the PowerShell validator). Run: python3 tests/test_configs.py
"""

import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONFIGS = ROOT / "configs"

ALLOWED_VALUES = {
    "vGPU": {"Enable", "Disable", "Default"},
    "Networking": {"Enable", "Disable", "Default"},
    "AudioInput": {"Enable", "Disable", "Default"},
    "VideoInput": {"Enable", "Disable", "Default"},
    "ProtectedClient": {"Enable", "Disable", "Default"},
    "PrinterRedirection": {"Enable", "Disable", "Default"},
    "ClipboardRedirection": {"Enable", "Disable", "Default"},
}

# Every shipped profile must set exactly these, so a typo that drops
# an option (and silently reverts it to a permissive default) fails.
REQUIRED = set(ALLOWED_VALUES) | {"MemoryInMB"}

EXPECTED = {
    "untrusted.wsb": {
        "vGPU": "Disable",
        "Networking": "Disable",
        "AudioInput": "Disable",
        "VideoInput": "Disable",
        "ProtectedClient": "Enable",
        "PrinterRedirection": "Disable",
        "ClipboardRedirection": "Disable",
        "MemoryInMB": "4096",
    },
    "installer-test.wsb": {
        "vGPU": "Enable",
        "Networking": "Enable",
        "ClipboardRedirection": "Disable",
    },
    "dev-test.wsb": {
        "vGPU": "Enable",
        "Networking": "Enable",
        "ClipboardRedirection": "Enable",
    },
}


def load(name):
    return ET.parse(CONFIGS / name).getroot()


class TestShippedConfigs(unittest.TestCase):
    def test_profiles_exist(self):
        found = sorted(p.name for p in CONFIGS.glob("*.wsb"))
        self.assertEqual(found, sorted(EXPECTED), f"shipped profiles changed: {found}")

    def test_schema_and_values(self):
        for name in EXPECTED:
            with self.subTest(profile=name):
                root = load(name)
                self.assertEqual(root.tag, "Configuration")
                values = {}
                for child in root:
                    self.assertNotIn(child.tag, values, f"duplicate <{child.tag}>")
                    if child.tag in ALLOWED_VALUES:
                        self.assertIn(
                            child.text, ALLOWED_VALUES[child.tag],
                            f"<{child.tag}>={child.text!r}",
                        )
                    if child.tag == "MemoryInMB":
                        memory = int(child.text)
                        self.assertGreaterEqual(memory, 2048)
                    values[child.tag] = child.text
                self.assertTrue(
                    REQUIRED.issubset(values),
                    f"missing options (a missing option silently reverts to its default): "
                    f"{sorted(REQUIRED - set(values))}",
                )
                # Shipped profiles map no folder: a profile that maps a
                # folder only works on a machine where that folder exists.
                self.assertNotIn("MappedFolders", values)
                self.assertNotIn("LogonCommand", values)

    def test_expected_profile_values(self):
        for name, expected in EXPECTED.items():
            with self.subTest(profile=name):
                root = load(name)
                values = {child.tag: child.text for child in root}
                for key, value in expected.items():
                    self.assertEqual(values.get(key), value, f"<{key}>")

    def test_no_placeholders_or_secrets(self):
        for path in CONFIGS.glob("*.wsb"):
            text = path.read_text(encoding="utf-8")
            for token in ("TODO", "XXX", "password", "api_key", "C:\\Users\\<"):
                self.assertNotIn(token, text, f"{path.name} contains {token!r}")


if __name__ == "__main__":
    unittest.main(verbosity=2)
