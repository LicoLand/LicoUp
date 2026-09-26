"""The native executable sample is compiled and driven as a real process.

It proves the same contract is implementable without a managed runtime: the
binary below is built from `agent.c` with the C compiler the repository already
needs to link Rust, and then driven exactly like the Python samples.
"""
from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from harness import ROOT, Session, replay

SAMPLE_DIR = ROOT / "sdk" / "agent-adapter" / "samples" / "native-executable"
SOURCE = SAMPLE_DIR / "agent.c"


class NativeExecutableTests(unittest.TestCase):
    binary: Path

    @classmethod
    def setUpClass(cls):
        compiler = shutil.which("cc")
        if compiler is None:
            raise unittest.SkipTest(
                "cc is not available to build the native sample; this environment "
                "cannot produce native-executable evidence"
            )
        cls._tempdir = tempfile.mkdtemp(prefix="v71-agent-sdk-native-")
        cls.binary = Path(cls._tempdir) / "agent"
        completed = subprocess.run(
            [
                compiler,
                "-std=c11",
                "-O2",
                "-Wall",
                "-Wextra",
                "-o",
                str(cls.binary),
                str(SOURCE),
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        if completed.returncode != 0:
            raise AssertionError(
                f"the native sample did not build:\n{completed.stderr}"
            )

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls._tempdir, ignore_errors=True)

    def session(self, **keywords) -> Session:
        return Session([str(self.binary)], **keywords)

    def test_handshake_verbatim_replies_and_duplicate_admission(self):
        with self.session() as client:
            client.initialize()
            description = client.describe()
            self.assertEqual(description["id"], "dev.example.agent.sdk.native")
            self.assertEqual(description["usage"], "unavailable")
            self.assertEqual(description["cancel"], "unsupported")

            text = 'json-looking {"not":"an envelope"} 雪 and \\ backslash'
            self.assertEqual(client.execute("native-1", text)["outcome"], "accepted")
            events = client.events_for("native-1")
            delivered = "".join(
                event["body"] for event in events if event["kind"] == "text"
            )
            self.assertEqual(delivered, text)
            self.assertEqual(events[-1]["body"]["outcome"], "succeeded")

            self.assertEqual(client.execute("native-1", text)["outcome"], "duplicate")
            self.assertEqual(
                sum(
                    candidate["params"]["kind"] == "terminal"
                    for candidate in client.frames
                    if candidate.get("method") == "agent.event"
                    and candidate["params"]["invocationRef"] == "native-1"
                ),
                1,
            )

    def test_unicode_and_empty_input_round_trip(self):
        with self.session() as client:
            client.initialize()
            for index, text in enumerate(["雪 line\nsecond", "", "quote\" backslash\\ tab\t"]):
                reference = f"native-empty-{index}"
                client.execute(reference, text)
                events = client.events_for(reference)
                delivered = "".join(
                    event["body"] for event in events if event["kind"] == "text"
                )
                self.assertEqual(delivered, text)

    def test_negotiated_bound_applies_to_every_frame(self):
        text = "abc雪\n" * 200
        with self.session(bound=4096) as client:
            client.initialize(bound=4096)
            self.assertEqual(client.initialize_response["result"]["maxFrameBytes"], 4096)
            client.execute("native-3", text)
            events = client.events_for("native-3", timeout=30.0)
            for raw in client.raw_lines:
                self.assertLessEqual(len(raw.rstrip(b"\n")), 4096)
            delivered = "".join(
                event["body"] for event in events if event["kind"] == "text"
            )
            self.assertEqual(delivered, text)

    def test_oversize_frame_is_refused_and_the_process_exits(self):
        with self.session(bound=4096) as client:
            client.initialize(bound=4096)
            client.send_raw(b'{"jsonrpc":"2.0","id":7,"method":"agent.describe","params":{"pad":"'
                            + b"x" * 5000
                            + b'"}}\n')
            refusal = client.wait_for(
                lambda candidate: "error" in candidate, timeout=5.0, what="framing error"
            )
            self.assertEqual(refusal["error"]["message"], "frame_too_large")
            self.assertEqual(client.process.wait(timeout=5.0), 2)

    def test_a_legal_id_is_echoed_completely_in_every_response(self):
        # The reviewer repro: a raw id of exactly 256 bytes (254 content bytes
        # plus quotes) is legal, and every response that echoes an id must
        # carry it in full and stay valid JSON. The answerability limit itself
        # follows the negotiated bound, so under the default 64 KiB bound a
        # 300-byte id is answerable too.
        with self.session() as client:
            client.initialize()

            for label, content in [("under", 253), ("at", 254), ("longer", 300)]:
                with self.subTest(label=label):
                    request_id = "d" * content
                    request = client.send_request("agent.describe", {}, request_id=request_id)
                    response = client.wait_response(request)
                    self.assertEqual(response["id"], request_id)
                    self.assertEqual(
                        response["result"]["id"], "dev.example.agent.sdk.native"
                    )

            receipt_id = "e" * 254
            request = client.send_request(
                "agent.execute",
                {"invocationRef": "boundary-ref", "input": "hello"},
                request_id=receipt_id,
            )
            receipt = client.wait_response(request)["result"]
            self.assertEqual(receipt["invocationRef"], "boundary-ref")
            self.assertEqual(
                client.events_for("boundary-ref")[-1]["body"]["outcome"],
                "succeeded",
            )

            error_id = "f" * 254
            request = client.send_request("agent.not-a-method", {}, request_id=error_id)
            error = client.wait_error(request)
            self.assertEqual(error["id"], error_id)
            self.assertEqual(error["error"]["code"], -32601)

            shutdown_id = "s" * 254
            request = client.send_request("extension.shutdown", {}, request_id=shutdown_id)
            shutdown = client.wait_response(request)
            self.assertEqual(shutdown["id"], shutdown_id)
            self.assertEqual(shutdown["result"], {"outcome": "stopped"})
            self.assertEqual(client.process.wait(timeout=5.0), 0)

    def test_the_answerability_limit_follows_the_negotiated_bound(self):
        with self.session(bound=4096) as client:
            client.initialize(bound=4096)
            # The exact reviewer scenario under a 4096-byte bound: a raw id of
            # 256 bytes in describe, then a normal shutdown.
            request = client.send_request("agent.describe", {}, request_id="x" * 254)
            self.assertEqual(client.wait_response(request)["id"], "x" * 254)

            # 4096 - 512 reserve: a raw id of 3584 bytes is answerable.
            at_limit = "b" * 3582
            request = client.send_request("agent.describe", {}, request_id=at_limit)
            response = client.wait_response(request)
            self.assertEqual(response["id"], at_limit)
            for raw in client.raw_lines:
                self.assertLessEqual(len(raw.rstrip(b"\n")), 4096)

            # One byte more has no response inside the bound: a bounded refusal
            # that reflects nothing, and the session continues.
            over_limit = "c" * 3583
            client.send_request("agent.describe", {}, request_id=over_limit)
            refusal = client.wait_for(
                lambda frame: "error" in frame, timeout=5.0, what="id bound refusal"
            )
            self.assertIsNone(refusal["id"])
            self.assertEqual(refusal["error"]["code"], -32001)
            self.assertEqual(
                refusal["error"]["message"],
                "request_id_exceeds_negotiated_frame_bound",
            )
            self.assertFalse(any(over_limit in line.decode() for line in client.raw_lines))
            self.assertEqual(client.describe()["id"], "dev.example.agent.sdk.native")

    def test_invalid_and_non_finite_ids_are_refused_not_reflected(self):
        invalid_tokens = [
            b"Infinity",
            b"NaN",
            b"+1",
            b"01",
            b"1.",
            b".5",
            b"1e999",
            b"true",
            b"[1]",
            b'{"a":1}',
            b'"raw\x01control"',
        ]
        with self.session() as client:
            client.initialize()
            for token in invalid_tokens:
                with self.subTest(token=token):
                    client.send_raw(
                        b'{"jsonrpc":"2.0","id":'
                        + token
                        + b',"method":"agent.describe","params":{}}\n'
                    )
                    refusal = client.wait_for(
                        lambda frame: "error" in frame, timeout=5.0, what="id refusal"
                    )
                    self.assertEqual(refusal["error"]["code"], -32600)
                    self.assertIsNone(refusal["id"])

            # A correctly escaped string id is valid JSON, so it is echoed as
            # it arrived and parses back to the original value.
            client.send_raw(
                b'{"jsonrpc":"2.0","id":"a\\u0001b","method":"agent.describe","params":{}}\n'
            )
            response = client.wait_for(
                lambda frame: "result" in frame, timeout=5.0, what="escaped id response"
            )
            self.assertEqual(response["id"], "a\u0001b")

            # A finite JSON number id is echoed as it arrived.
            client.send_raw(
                b'{"jsonrpc":"2.0","id":1e308,"method":"agent.describe","params":{}}\n'
            )
            response = client.wait_for(
                lambda frame: "result" in frame, timeout=5.0, what="numeric id response"
            )
            self.assertEqual(response["id"], 1e308)

            # The session continues after every refusal.
            self.assertEqual(client.describe()["id"], "dev.example.agent.sdk.native")

    def test_a_reference_with_quotes_backslashes_and_controls_round_trips(self):
        with self.session() as client:
            client.initialize()
            reference = 'ref"quote\\slash\ttab'
            receipt = client.execute(reference, "hello")
            self.assertEqual(receipt["invocationRef"], reference)
            events = client.events_for(reference)
            self.assertEqual(
                [event["invocationRef"] for event in events],
                [reference] * len(events),
            )
            self.assertEqual(events[-1]["body"]["outcome"], "succeeded")

    def test_unsupported_optional_methods_are_refused_and_execution_continues(self):
        with self.session() as client:
            client.initialize()
            cancel_id = client.send_request(
                "agent.cancel", {"invocationRef": "native-4"}
            )
            self.assertEqual(client.wait_error(cancel_id)["error"]["code"], -32601)
            client.execute("native-5", "after refusal")
            self.assertEqual(client.events_for("native-5")[-1]["kind"], "terminal")

    def test_the_recorded_session_replays_byte_for_byte(self):
        stdout, stderr, returncode = replay(
            [str(self.binary)], SAMPLE_DIR / "transcript.jsonl"
        )
        self.assertEqual(returncode, 0, stderr.decode("utf-8", errors="replace"))
        self.assertEqual(stdout, (SAMPLE_DIR / "events.jsonl").read_bytes())


if __name__ == "__main__":
    unittest.main()
