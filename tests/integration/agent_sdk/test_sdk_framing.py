"""The SDK's framing promises are checked without starting a process.

These are the rules every adapter inherits: a text body is split so no frame
exceeds the negotiated bound, reassembly is exact, sequences are monotone, and
nothing is emitted after a terminal event.
"""
from __future__ import annotations

import sys
import threading
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "sdk" / "agent-adapter" / "python"))

import licoup_agent_sdk as sdk


class FakeCarrier:
    """Only what the Emitter needs: a write lock and a place to put frames."""

    def __init__(self) -> None:
        self.write_lock = threading.RLock()
        self.frames: list[dict] = []

    def write(self, frame: dict) -> None:
        self.frames.append(frame)


class EmitterFramingTests(unittest.TestCase):
    def test_text_is_chunked_in_bounds_and_reassembles_exactly(self):
        carrier = FakeCarrier()
        emitter = sdk.Emitter(carrier, "inv-1", 4096)
        text = ('plain "quoted" \\backslash\\ 雪 line\n\t' * 400)
        emitter.text(text)
        self.assertGreater(len(carrier.frames), 1, "the text must have been split")
        for frame in carrier.frames:
            self.assertEqual(frame["method"], "agent.event")
            self.assertEqual(frame["params"]["kind"], "text")
            self.assertLessEqual(sdk.frame_bytes(frame), 4096)
        self.assertEqual(
            "".join(frame["params"]["body"] for frame in carrier.frames), text
        )
        self.assertEqual(
            [frame["params"]["sequence"] for frame in carrier.frames],
            list(range(1, len(carrier.frames) + 1)),
        )

    def test_an_empty_reply_is_one_event_and_not_an_abstention(self):
        carrier = FakeCarrier()
        emitter = sdk.Emitter(carrier, "inv-2", 4096)
        emitter.text("")
        self.assertEqual(len(carrier.frames), 1)
        self.assertEqual(carrier.frames[0]["params"]["body"], "")

    def test_nothing_is_emitted_after_terminal(self):
        carrier = FakeCarrier()
        emitter = sdk.Emitter(carrier, "inv-3", 4096)
        emitter.text("before")
        emitter.terminal({"outcome": "succeeded"})
        emitter.text("after")
        emitter.terminal({"outcome": "failed"})
        kinds = [frame["params"]["kind"] for frame in carrier.frames]
        self.assertEqual(kinds, ["text", "terminal"])
        self.assertEqual([frame["params"]["sequence"] for frame in carrier.frames], [1, 2])

    def test_the_bound_is_never_exceeded_by_the_refusal_path(self):
        carrier = FakeCarrier()
        # A frame larger than the bound is replaced by a bounded refusal rather
        # than reflected at a size the host never agreed to carry.
        emitter = sdk.Emitter(carrier, "x" * sdk.MAX_INVOCATION_REFERENCE_BYTES, 4096)
        emitter.text("雪" * 400)
        for frame in carrier.frames:
            self.assertLessEqual(sdk.frame_bytes(frame), 4096)

    def test_usage_frames_carry_the_observation_verbatim(self):
        carrier = FakeCarrier()
        emitter = sdk.Emitter(carrier, "inv-4", 4096)
        observation = sdk.usage_observation(
            scope_ref="inv-4",
            observation_id="inv-4/items",
            metrics={"dev.example.agent/items": {"value": "1", "unit": "items",
                                                 "temporality": "delta",
                                                 "quality": "reported"}},
            observed_at="2026-01-01T00:00:00Z",
            source_epoch="epoch-1",
        )
        emitter.usage(observation)
        self.assertEqual(carrier.frames[0]["method"], "usage.publish")
        self.assertEqual(carrier.frames[0]["params"], observation)


if __name__ == "__main__":
    unittest.main()
