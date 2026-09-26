"""The minimal specialist is a complete Agent, driven as a real subprocess.

These cases are component integration: they start the sample the way a host
would, over a pipe, and assert the observable wire behavior. No model, no
network and no client build are involved.
"""
from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from harness import ROOT, Session, WireError, replay

SAMPLE_DIR = ROOT / "sdk" / "agent-adapter" / "samples" / "minimal-specialist"
AGENT = SAMPLE_DIR / "agent.py"


def session(**keywords) -> Session:
    return Session([sys.executable, "-B", str(AGENT)], **keywords)


class MinimalSpecialistTests(unittest.TestCase):
    def test_handshake_ready_and_capability_honesty(self):
        with session() as client:
            response = client.initialize()
            result = response["result"]
            self.assertEqual(result["protocol"]["major"], 1)
            self.assertEqual(result["maxFrameBytes"], client.bound)
            self.assertEqual(result["profiles"], ["agent-execution"])
            self.assertIsNone(client.ready.get("id"), "readiness is a notification")
            self.assertEqual(client.ready["params"]["profiles"], ["agent-execution"])

            description = client.describe()
            self.assertEqual(description["id"], "dev.example.agent.sdk.minimal")
            self.assertEqual(description["interfaceVersion"], "1.0.0")
            self.assertEqual(description["usage"], "unavailable")
            self.assertEqual(description["cancel"], "unsupported")
            self.assertEqual(description["resume"], "unsupported")
            for capability in description["capabilities"]:
                self.assertIn("/", capability)

    def test_plain_json_looking_unicode_and_empty_replies_are_verbatim(self):
        for text in [
            "A plain reply with no required marker.",
            '{"principal":"not authority","state":"not a receipt"',
            "第一行\n第二行 雪",
            "",
        ]:
            with self.subTest(text=text[:24]):
                with session() as client:
                    client.initialize()
                    receipt = client.execute("synthetic-1", text)
                    self.assertEqual(receipt["outcome"], "accepted")
                    events = client.events_for("synthetic-1")
                    self.assertEqual(
                        [event["sequence"] for event in events],
                        list(range(1, len(events) + 1)),
                    )
                    self.assertEqual(events[-1]["kind"], "terminal")
                    self.assertEqual(
                        sum(event["kind"] == "terminal" for event in events), 1
                    )
                    delivered = "".join(
                        event["body"] for event in events if event["kind"] == "text"
                    )
                    self.assertEqual(delivered, text)

    def test_a_duplicate_invocation_is_not_executed_twice(self):
        with session() as client:
            client.initialize()
            first = client.execute("synthetic-2", "once")
            second = client.execute("synthetic-2", "once")
            self.assertEqual(first["outcome"], "accepted")
            self.assertEqual(second["outcome"], "duplicate")
            events = client.events_for("synthetic-2")
            self.assertEqual(sum(event["kind"] == "terminal" for event in events), 1)
            replayed = "".join(
                event["body"] for event in events if event["kind"] == "text"
            )
            self.assertEqual(replayed, "once")

    def test_unsupported_optional_methods_do_not_break_execution(self):
        with session() as client:
            client.initialize()
            cancel_id = client.send_request(
                "agent.cancel", {"invocationRef": "synthetic-3"}
            )
            error = client.wait_error(cancel_id)
            self.assertEqual(error["error"]["code"], -32601)
            self.assertEqual(error["error"]["message"], "unsupported_method")

            resume_id = client.send_request(
                "agent.resume", {"priorInvocationRef": "synthetic-3", "cursor": ""}
            )
            self.assertEqual(client.wait_error(resume_id)["error"]["code"], -32601)

            # A missing optional ability refuses only its own method.
            self.assertEqual(client.execute("synthetic-4", "still works")["outcome"], "accepted")
            events = client.events_for("synthetic-4")
            self.assertEqual(events[-1]["kind"], "terminal")

    def test_negotiated_bound_applies_to_every_frame(self):
        text = "line 雪\n" * 200
        with session(bound=4096) as client:
            client.initialize(bound=4096)
            self.assertEqual(client.initialize_response["result"]["maxFrameBytes"], 4096)
            client.execute("synthetic-5", text)
            events = client.events_for("synthetic-5")
            for raw in client.raw_lines:
                self.assertLessEqual(len(raw.rstrip(b"\n")), 4096)
            delivered = "".join(
                event["body"] for event in events if event["kind"] == "text"
            )
            self.assertEqual(delivered, text)

    def test_calls_before_initialize_and_incompatible_majors_are_refused(self):
        with session() as client:
            early_id = client.send_request("agent.describe")
            early = client.wait_error(early_id)
            self.assertEqual(early["error"]["message"], "not_initialized")

            incompatible_id = client.send_request(
                "extension.initialize", {"protocol": {"major": 2}, "maxFrameBytes": 65536}
            )
            incompatible = client.wait_error(incompatible_id)
            self.assertEqual(incompatible["error"]["message"], "incompatible_protocol")

            # Still answerable by the published major.
            client.initialize()
            self.assertEqual(client.describe()["id"], "dev.example.agent.sdk.minimal")

    def test_oversize_frame_is_a_framing_fault_and_never_starts_work(self):
        with session(bound=4096) as client:
            client.initialize(bound=4096)
            oversized = {
                "jsonrpc": "2.0",
                "id": 99,
                "method": "agent.execute",
                "params": {"invocationRef": "synthetic-6", "input": "x" * 5000},
            }
            client.send_raw(json.dumps(oversized).encode("utf-8") + b"\n")
            frame = client.wait_for(
                lambda candidate: "error" in candidate, timeout=5.0, what="framing error"
            )
            self.assertEqual(frame["error"]["message"], "frame_too_large")
            self.assertIsNone(frame["id"])
            self.assertEqual(client.process.wait(timeout=5.0), 2)
            self.assertFalse(
                any(candidate.get("method") == "agent.event" for candidate in client.frames)
            )

    def test_invalid_reference_and_malformed_id_are_refused_without_reflection(self):
        with session() as client:
            client.initialize()
            long_reference = "x" * 161
            reference_id = client.send_request(
                "agent.execute", {"invocationRef": long_reference, "input": "must not run"}
            )
            error = client.wait_error(reference_id)
            self.assertEqual(error["error"]["message"], "invalid_invocation_ref")
            self.assertFalse(
                any(candidate.get("method") == "agent.event" for candidate in client.frames)
            )
            self.assertFalse(
                any(long_reference in line.decode() for line in client.raw_lines)
            )

            malformed = (
                b'{"jsonrpc":"2.0","id":{"nested":true},"method":"agent.describe","params":{}}\n'
            )
            client.send_raw(malformed)
            refusal = client.wait_for(
                lambda candidate: "error" in candidate, timeout=5.0, what="id refusal"
            )
            self.assertEqual(refusal["error"]["code"], -32600)
            self.assertIsNone(refusal["id"])

            # A malformed request does not poison the session.
            self.assertEqual(client.describe()["id"], "dev.example.agent.sdk.minimal")

    def test_a_notification_is_never_answered_and_admission_needs_a_receipt(self):
        with session() as client:
            client.initialize()
            describe_id = client.send_request("agent.describe")
            client.wait_response(describe_id)
            client.send_notification("agent.cancel", {"invocationRef": "synthetic-7"})
            client.send_notification("future.method", {})
            client.send_notification(
                "agent.execute",
                {"invocationRef": "synthetic-8", "input": "must not run"},
            )
            probe_id = client.send_request("agent.describe")
            client.wait_response(probe_id)
            self.assertFalse(
                any(
                    frame.get("method") is None and frame.get("id") is None
                    for frame in client.frames
                ),
                "a notification produced a response",
            )
            self.assertFalse(
                any(
                    frame.get("method") == "agent.event"
                    and frame["params"]["invocationRef"] == "synthetic-8"
                    for frame in client.frames
                ),
                "work was admitted without a receipt",
            )

    def test_the_recorded_session_replays_byte_for_byte(self):
        stdout, stderr, returncode = replay(
            [sys.executable, "-B", str(AGENT)], SAMPLE_DIR / "transcript.jsonl"
        )
        self.assertEqual(returncode, 0, stderr.decode("utf-8", errors="replace"))
        expected = (SAMPLE_DIR / "events.jsonl").read_bytes()
        self.assertEqual(
            stdout,
            expected,
            "the sample no longer reproduces its recorded session",
        )


if __name__ == "__main__":
    unittest.main()
