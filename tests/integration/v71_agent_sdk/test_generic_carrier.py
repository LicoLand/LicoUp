"""The generic carrier turns an existing CLI into an Agent through data alone.

Every case below runs the carrier as a real process and starts a real child
command. The descriptor is the only thing that names the command; the carrier
has no vendor switch, and the wrapped program is never modified.
"""
from __future__ import annotations

import json
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from harness import ROOT, Session, replay

GENERIC_DIR = ROOT / "extensions" / "generic"
CARRIER = GENERIC_DIR / "generic_carrier.py"
SAMPLE_DESCRIPTOR = GENERIC_DIR / "descriptor.json"
ECHO_CLI = GENERIC_DIR / "echo_cli.py"


def write_descriptor(directory: Path, **overrides) -> Path:
    descriptor = {
        "schema": "licoup.generic-adapter.v1",
        "id": "dev.example.agent.test-cli",
        "displayName": "Test CLI adapter",
        "command": [sys.executable, "-B", str(ECHO_CLI)],
        "input": "stdin-text",
        "output": "stdout-lines",
        "terminal": "exit-code",
        "cancel": "terminate",
        "capabilities": ["dev.example.agent/stream"],
        "cwd": ".",
    }
    descriptor.update(overrides)
    for key in [key for key, value in descriptor.items() if value is None]:
        del descriptor[key]
    path = directory / "descriptor.json"
    path.write_text(json.dumps(descriptor, indent=2), encoding="utf-8")
    return path


def carrier(descriptor: Path, **keywords) -> Session:
    return Session(
        [sys.executable, "-B", str(CARRIER), str(descriptor)],
        cwd=ROOT,
        **keywords,
    )


class GenericCarrierTests(unittest.TestCase):
    def test_the_sample_descriptor_carries_the_existing_cli(self):
        with carrier(SAMPLE_DESCRIPTOR) as client:
            client.initialize()
            description = client.describe()
            self.assertEqual(description["id"], "dev.example.agent.echo-cli")
            self.assertEqual(description["instanceKind"], "cli-adapter")

            client.execute("cli-1", "alpha\nbeta\n")
            events = client.events_for("cli-1")
            texts = [
                event["body"] for event in events if event["kind"] == "text"
            ]
            self.assertEqual(texts, ["echo: alpha\n", "echo: beta\n"])
            self.assertEqual(events[-1]["body"]["outcome"], "succeeded")

    def test_the_manifest_entry_finds_its_default_descriptor(self):
        # The package manifest names generic_carrier.py as the entry; started
        # that way there is no descriptor argument, so the carrier reads
        # descriptor.json next to itself.
        with Session(
            [sys.executable, "-B", str(CARRIER)], cwd=GENERIC_DIR
        ) as client:
            client.initialize()
            self.assertEqual(client.describe()["id"], "dev.example.agent.echo-cli")

    def test_descriptors_are_refused_strictly(self):
        cases = [
            ("unknown field", {"futureKey": True}, "descriptor_unknown_fields"),
            ("missing command", {"command": None}, "descriptor_missing_fields"),
            ("wrong schema", {"schema": "other.v1"}, "descriptor_schema_mismatch"),
            ("bare id", {"id": "echo"}, "descriptor_id_invalid"),
            ("empty command", {"command": []}, "descriptor_command_invalid"),
            ("nul in command", {"command": ["python3", "a\u0000b"]},
             "descriptor_command_invalid"),
            ("unknown cancel", {"cancel": "kill"}, "descriptor_cancel_invalid"),
            ("unnamespaced capability", {"capabilities": ["stream"]},
             "descriptor_capabilities_invalid"),
        ]
        with tempfile.TemporaryDirectory(prefix="v71-carrier-descriptor-") as directory:
            for label, override, expected in cases:
                with self.subTest(label=label):
                    descriptor = write_descriptor(Path(directory), **override)
                    completed = subprocess.run(
                        [sys.executable, "-B", str(CARRIER), str(descriptor)],
                        cwd=str(ROOT),
                        stdin=subprocess.DEVNULL,
                        capture_output=True,
                        text=True,
                        timeout=30,
                        check=False,
                    )
                    self.assertEqual(completed.returncode, 2)
                    self.assertIn(expected, completed.stderr)

    def test_unsupported_cancel_is_honest_and_execution_continues(self):
        with tempfile.TemporaryDirectory(prefix="v71-carrier-unsupported-") as directory:
            descriptor = write_descriptor(
                Path(directory),
                cancel="unsupported",
                command=[sys.executable, "-B", str(ECHO_CLI), "--slow"],
            )
            with carrier(descriptor) as client:
                client.initialize()
                self.assertEqual(client.describe()["cancel"], "unsupported")
                cancel_id = client.send_request(
                    "agent.cancel", {"invocationRef": "cli-2"}
                )
                self.assertEqual(client.wait_error(cancel_id)["error"]["code"], -32601)
                client.execute("cli-3", "still served\n")
                events = client.events_for("cli-3")
                self.assertEqual(events[-1]["body"]["outcome"], "succeeded")

    def test_cancelling_a_running_command_stops_the_child(self):
        with tempfile.TemporaryDirectory(prefix="v71-carrier-cancel-") as directory:
            descriptor = write_descriptor(
                Path(directory),
                command=[sys.executable, "-B", str(ECHO_CLI), "--slow"],
            )
            with carrier(descriptor) as client:
                client.initialize()
                lines = "".join(f"line {index}\n" for index in range(200))
                client.execute("cli-4", lines)
                first = client.wait_method("agent.event")
                self.assertEqual(first["params"]["invocationRef"], "cli-4")

                cancel_id = client.send_request(
                    "agent.cancel", {"invocationRef": "cli-4"}
                )
                cancel = client.wait_response(cancel_id, timeout=10.0)["result"]
                self.assertEqual(cancel["outcome"], "acknowledged")

                events = client.events_for("cli-4")
                self.assertEqual(events[-1]["kind"], "terminal")
                self.assertEqual(events[-1]["body"]["outcome"], "cancelled")
                delivered = "".join(
                    event["body"] for event in events if event["kind"] == "text"
                )
                self.assertLess(len(delivered), len(lines), "the child kept streaming")

                # One terminal, and the process is still serving new work.
                client.request("agent.describe")
                self.assertEqual(
                    sum(
                        candidate.get("method") == "agent.event"
                        and candidate["params"]["invocationRef"] == "cli-4"
                        and candidate["params"]["kind"] == "terminal"
                        for candidate in client.frames
                    ),
                    1,
                )
                client.execute("cli-5", "after cancel\n")
                self.assertEqual(
                    client.events_for("cli-5")[-1]["body"]["outcome"], "succeeded"
                )

    def test_bulk_output_stays_bounded_and_complete(self):
        with tempfile.TemporaryDirectory(prefix="v71-carrier-bulk-") as directory:
            descriptor = write_descriptor(
                Path(directory),
                command=[sys.executable, "-B", str(ECHO_CLI), "--bulk", "2000"],
            )
            with carrier(descriptor, bound=4096) as client:
                client.initialize(bound=4096)
                client.execute("cli-6", "")
                events = client.events_for("cli-6", timeout=60.0)
                for raw in client.raw_lines:
                    self.assertLessEqual(len(raw.rstrip(b"\n")), 4096)
                delivered = "".join(
                    event["body"] for event in events if event["kind"] == "text"
                )
                self.assertIn("bulk line 0\n", delivered)
                self.assertIn("bulk line 1999\n", delivered)
                self.assertEqual(delivered.count("\n"), 2000)
                self.assertEqual(events[-1]["body"]["outcome"], "succeeded")

    def test_cancel_is_answered_while_bulk_output_is_flowing(self):
        with tempfile.TemporaryDirectory(prefix="v71-carrier-flow-") as directory:
            descriptor = write_descriptor(
                Path(directory),
                command=[
                    sys.executable,
                    "-B",
                    str(ECHO_CLI),
                    "--bulk",
                    "2000",
                    "--slow",
                ],
            )
            with carrier(descriptor, bound=4096) as client:
                client.initialize(bound=4096)
                client.execute("cli-7", "")
                client.wait_method("agent.event")
                started = time.monotonic()
                cancel_id = client.send_request(
                    "agent.cancel", {"invocationRef": "cli-7"}
                )
                cancel = client.wait_response(cancel_id, timeout=5.0)["result"]
                elapsed = time.monotonic() - started
                self.assertEqual(cancel["outcome"], "acknowledged")
                self.assertLess(
                    elapsed,
                    2.0,
                    "a control frame queued behind bulk data output",
                )
                events = client.events_for("cli-7")
                self.assertEqual(events[-1]["body"]["outcome"], "cancelled")

    def test_the_recorded_session_replays_byte_for_byte(self):
        stdout, stderr, returncode = replay(
            [sys.executable, "-B", str(CARRIER), str(SAMPLE_DESCRIPTOR)],
            GENERIC_DIR / "transcript.jsonl",
        )
        self.assertEqual(returncode, 0, stderr.decode("utf-8", errors="replace"))
        self.assertEqual(stdout, (GENERIC_DIR / "events.jsonl").read_bytes())


if __name__ == "__main__":
    unittest.main()
