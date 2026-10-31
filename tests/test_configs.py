"""Schema and profile checks for the shipped .wsb files.

The schema lives in schema/wsb-schema.json and is the single source
of truth for the PowerShell generator and validator. These tests
check three different things, and the distinction matters:

1. The schema itself matches Microsoft's documented option set
   (MICROSOFT_ALLOWED, hardcoded here on purpose as an independent
   oracle -- if someone edits the schema to a wrong value, this
   test, not the schema, is what catches it).
2. Every shipped profile matches the schema's profile definition
   exactly (so the .wsb files cannot drift from the generator).
3. The locked-down Untrusted profile is locked down, regardless
   of what the schema says (UNTRUSTED_EXPECTED, hardcoded here as
   a security invariant -- weakening Untrusted in the schema must
   fail a test, not just change a generated file).

Run: python3 tests/test_configs.py
"""

import json
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CONFIGS = ROOT / "configs"
SCHEMA_PATH = ROOT / "schema" / "wsb-schema.json"
OPTIONS_DOC = ROOT / "docs" / "options.md"

# Microsoft's documented Enable/Disable/Default options. Hardcoded
# deliberately: this is the oracle the schema is checked against.
MICROSOFT_ALLOWED = {
    "vGPU": {"Enable", "Disable", "Default"},
    "Networking": {"Enable", "Disable", "Default"},
    "AudioInput": {"Enable", "Disable", "Default"},
    "VideoInput": {"Enable", "Disable", "Default"},
    "ProtectedClient": {"Enable", "Disable", "Default"},
    "PrinterRedirection": {"Enable", "Disable", "Default"},
    "ClipboardRedirection": {"Enable", "Disable", "Default"},
}

# Security invariant for the Untrusted profile. Hardcoded deliberately:
# if the schema ever weakens this profile, this test must fail.
UNTRUSTED_EXPECTED = {
    "vGPU": "Disable",
    "Networking": "Disable",
    "AudioInput": "Disable",
    "VideoInput": "Disable",
    "ProtectedClient": "Enable",
    "PrinterRedirection": "Disable",
    "ClipboardRedirection": "Disable",
    "MemoryInMB": "4096",
}


def load_schema():
    """Load schema/wsb-schema.json, failing loudly if it is broken."""
    return json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))


def load_profile(name):
    """Parse a shipped .wsb file into an element-name -> text dict."""
    root = ET.parse(CONFIGS / name).getroot()
    if root.tag != "Configuration":
        raise AssertionError(f"{name}: root element is {root.tag!r}, not 'Configuration'")
    values = {}
    for child in root:
        if child.tag in values:
            raise AssertionError(f"{name}: duplicated <{child.tag}>")
        # An empty element (<Networking/>) has text None, which is
        # neither a valid value nor a useful error from int() below.
        if child.text is None:
            raise AssertionError(f"{name}: <{child.tag}> is empty")
        values[child.tag] = child.text
    return values


class TestSchema(unittest.TestCase):
    """The schema file itself, checked against Microsoft's docs."""

    def test_schema_matches_microsoft_option_set(self):
        schema = load_schema()
        self.assertEqual(
            {k: set(v) for k, v in schema["optionValues"].items()},
            MICROSOFT_ALLOWED,
            "schema optionValues drifted from Microsoft's documented set",
        )
        self.assertEqual(schema["minMemoryInMB"], 2048)
        self.assertEqual(schema["defaultMemoryInMB"], 4096)

    def test_docs_mention_every_option(self):
        # The options table is documentation, not code, so it can
        # drift silently when the schema changes. This pins it: every
        # schema option must appear in docs/options.md.
        schema = load_schema()
        doc = OPTIONS_DOC.read_text(encoding="utf-8")
        for option in schema["optionValues"]:
            with self.subTest(option=option):
                self.assertIn(f"<{option}>", doc)


class TestShippedConfigs(unittest.TestCase):
    """Shipped .wsb files, checked against the schema and the invariant."""

    def test_profiles_exist_and_match_schema(self):
        schema = load_schema()
        found = sorted(p.name for p in CONFIGS.glob("*.wsb"))
        # Profile names in the schema are PascalCase (Untrusted);
        # shipped files are kebab-case (untrusted.wsb, dev-test.wsb).
        expected_files = sorted(
            name.replace("DevTest", "dev-test")
            .replace("InstallerTest", "installer-test")
            .replace("Untrusted", "untrusted")
            + ".wsb"
            for name in schema["profiles"]
        )
        self.assertEqual(found, expected_files, f"shipped profiles changed: {found}")
        file_by_profile = {
            "Untrusted": "untrusted.wsb",
            "DevTest": "dev-test.wsb",
            "InstallerTest": "installer-test.wsb",
        }
        for profile_name, profile in schema["profiles"].items():
            with self.subTest(profile=profile_name):
                values = load_profile(file_by_profile[profile_name])
                expected = {k: str(v) for k, v in profile.items()}
                self.assertEqual(values, expected)
                # Shipped profiles map no folder and run no logon
                # command: a profile that maps a folder only works
                # on a machine where that folder exists.
                self.assertNotIn("MappedFolders", values)
                self.assertNotIn("LogonCommand", values)

    def test_untrusted_profile_is_locked_down(self):
        values = load_profile("untrusted.wsb")
        for key, value in UNTRUSTED_EXPECTED.items():
            with self.subTest(option=key):
                self.assertEqual(values.get(key), value)

    def test_memory_values_are_numeric_and_sufficient(self):
        for path in CONFIGS.glob("*.wsb"):
            with self.subTest(profile=path.name):
                values = load_profile(path.name)
                try:
                    memory = int(values["MemoryInMB"])
                except (KeyError, ValueError) as exc:
                    self.fail(f"{path.name}: MemoryInMB is not a number: {exc}")
                self.assertGreaterEqual(memory, 2048)

    def test_no_placeholders_or_secrets(self):
        for path in CONFIGS.glob("*.wsb"):
            text = path.read_text(encoding="utf-8")
            for token in ("TODO", "XXX", "password", "api_key", "C:\\Users\\<"):
                self.assertNotIn(token, text, f"{path.name} contains {token!r}")


if __name__ == "__main__":
    unittest.main(verbosity=2)
