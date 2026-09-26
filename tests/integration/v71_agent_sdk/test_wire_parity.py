"""The SDK must not drift from the frozen contract crate.

Wire compatibility is the seam between the extension host and every adapter,
so these checks read the accepted contract crate and the published schemas and
compare them with what the SDK implements. A rename or a bound change in the
crate fails here instead of silently shipping two contracts.
"""
from __future__ import annotations

import json
import re
import unittest
from pathlib import Path

import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))

from harness import ROOT

sys.path.insert(0, str(ROOT / "sdk" / "agent-adapter" / "python"))

import licoup_agent_sdk as sdk

CRATE = ROOT / "crates" / "licoup-extension-contracts"
SCHEMAS = ROOT / "schemas" / "extensions"
SDK = ROOT / "sdk" / "agent-adapter" / "python" / "licoup_agent_sdk.py"

MANIFESTS = [
    ROOT / "sdk" / "agent-adapter" / "samples" / "minimal-specialist" / "manifest.json",
    ROOT / "sdk" / "agent-adapter" / "samples" / "full-agent" / "manifest.json",
    ROOT / "sdk" / "agent-adapter" / "samples" / "native-executable" / "manifest.json",
    ROOT / "extensions" / "generic" / "manifest.json",
]


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def usize_constant(source_text: str, name: str) -> int:
    match = re.search(rf"\b{re.escape(name)}\s*:\s*usize\s*=\s*([0-9_*\s]+);", source_text)
    if match is None:
        raise AssertionError(f"{name} is not declared in the contract crate")
    product = 1
    for factor in match.group(1).replace("_", "").split("*"):
        product *= int(factor.strip())
    return product


class WireParityTests(unittest.TestCase):
    def test_carrier_bounds_match_the_contract(self):
        transport = read(CRATE / "src" / "transport.rs")
        self.assertEqual(
            sdk.DEFAULT_MAX_FRAME_BYTES,
            usize_constant(transport, "DEFAULT_MAX_FRAME_BYTES"),
        )
        self.assertEqual(
            sdk.MIN_MAX_FRAME_BYTES,
            usize_constant(transport, "MIN_MAX_FRAME_BYTES"),
        )
        self.assertEqual(
            sdk.MAX_MAX_FRAME_BYTES,
            usize_constant(transport, "MAX_MAX_FRAME_BYTES"),
        )
        self.assertEqual(
            sdk.MAX_DIAGNOSTIC_LINE_BYTES,
            usize_constant(transport, "MAX_LOG_LINE_BYTES"),
        )
        agent = read(CRATE / "src" / "agent.rs")
        self.assertEqual(
            sdk.MAX_INVOCATION_REFERENCE_BYTES,
            usize_constant(agent, "MAX_INVOCATION_REFERENCE_BYTES"),
        )

    def test_profile_major_and_every_agent_method_are_implemented(self):
        profile = read(CRATE / "src" / "profile.rs")
        major = re.search(r"\bPROFILE_MAJOR\s*:\s*u32\s*=\s*(\d+);", profile)
        self.assertIsNotNone(major)
        self.assertEqual(sdk.PROTOCOL_MAJOR, int(major.group(1)))

        methods = re.findall(r'METHOD_[A-Z_]+\s*:\s*&str\s*=\s*"([^"]+)"', profile)
        self.assertTrue(methods)
        sdk_source = read(SDK)
        for method in methods:
            if method.startswith(("agent.", "extension.")):
                self.assertIn(
                    f'"{method}"',
                    sdk_source,
                    f"the SDK does not implement the published method {method}",
                )

    def test_wire_ids_match_the_published_schemas(self):
        lib = read(CRATE / "src" / "lib.rs")
        usage = re.search(r'pub const USAGE:\s*&str\s*=\s*"([^"]+)"', lib)
        self.assertIsNotNone(usage)
        self.assertEqual(
            sdk.usage_observation(
                scope_ref="s",
                observation_id="o",
                metrics={},
                observed_at="t",
                source_epoch="e",
            )["schema"],
            usage.group(1),
        )
        manifest_id = re.search(r'pub const MANIFEST:\s*&str\s*=\s*"([^"]+)"', lib)
        self.assertIsNotNone(manifest_id)
        for manifest_path in MANIFESTS:
            manifest = json.loads(read(manifest_path))
            self.assertEqual(manifest["schema"], manifest_id.group(1))

    def test_sample_manifests_carry_exactly_the_published_manifest_shape(self):
        schema = json.loads(read(SCHEMAS / "manifest.schema.json"))
        properties = set(schema["properties"])
        required = set(schema.get("required", []))
        for manifest_path in MANIFESTS:
            with self.subTest(manifest=manifest_path.name):
                manifest = json.loads(read(manifest_path))
                self.assertTrue(
                    required <= set(manifest),
                    f"{manifest_path.name} omits {sorted(required - set(manifest))}",
                )
                self.assertTrue(
                    set(manifest) <= properties,
                    f"{manifest_path.name} carries unpublished keys "
                    f"{sorted(set(manifest) - properties)}",
                )
                self.assertEqual(manifest["runtime"]["mode"], "process")
                for profile in manifest["profiles"]:
                    self.assertIn(profile["id"], (
                        "agent-execution",
                        "model-provider",
                        "usage-metric",
                        "package-deployment",
                        "declarative-ui",
                    ))

    def test_every_sample_declares_where_its_descriptor_or_entry_lives(self):
        for manifest_path in MANIFESTS:
            manifest = json.loads(read(manifest_path))
            runtime = manifest["runtime"]
            if runtime["mode"] == "process":
                entry = manifest_path.parent / runtime["entry"]
                buildable_source = manifest_path.parent / (entry.name + ".c")
                self.assertTrue(
                    entry.exists() or buildable_source.exists(),
                    f"{manifest_path.name} names an entry that does not exist: {entry}",
                )


if __name__ == "__main__":
    unittest.main()
