"""The full Agent negotiates real optional abilities and reports them honestly.

The contrast with the minimal specialist is the point: both are complete
extensions, and the difference is what `agent.describe` negotiates, not whether
basic execution works.
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from harness import ROOT, Session, replay

SAMPLE_DIR = ROOT / "sdk" / "agent-adapter" / "samples" / "full-agent"
AGENT = SAMPLE_DIR / "agent.py"


def session(**keywords) -> Session:
    return Session([sys.executable, "-B", str(AGENT)], **keywords)


def collect_events(client: Session, reference: str, count: int, timeout: float = 15.0):
    """Collect exactly `count` replay notifications for one invocation."""
    collected = []
    while len(collected) < count:
        frame = client.wait_for(
            lambda candidate: candidate.get("method") == "agent.event"
            and candidate["params"].get("invocationRef") == reference,
            timeout=timeout,
            what=f"replayed event {len(collected) + 1}/{count}",
        )
        collected.append(frame["params"])
    return collected


class FullAgentTests(unittest.TestCase):
    def test_describe_negotiates_the_optional_abilities(self):
        with session() as client:
            client.initialize()
            description = client.describe()
            self.assertEqual(description["usage"], "reported")
            self.assertEqual(description["cancel"], "supported")
            self.assertEqual(description["resume"], "supported")
            self.assertEqual(
                client.ready["params"]["profiles"], ["agent-execution", "usage-metric"]
            )

    def test_cancel_is_acknowledged_only_after_the_work_stopped(self):
        with session() as client:
            client.initialize()
            text = "x" * 2000
            self.assertEqual(client.execute("cancel-me", text)["outcome"], "accepted")
            first = client.wait_method("agent.event")
            self.assertEqual(first["params"]["invocationRef"], "cancel-me")
            self.assertEqual(first["params"]["kind"], "text")

            cancel_id = client.send_request("agent.cancel", {"invocationRef": "cancel-me"})
            cancel = client.wait_response(cancel_id, timeout=10.0)["result"]
            self.assertEqual(cancel["outcome"], "acknowledged")

            events = client.events_for("cancel-me")
            terminal = events[-1]
            self.assertEqual(terminal["kind"], "terminal")
            self.assertEqual(terminal["body"]["outcome"], "cancelled")
            delivered = "".join(
                event["body"] for event in events if event["kind"] == "text"
            )
            self.assertLess(len(delivered), len(text), "the work stopped early")

            # A finished invocation cannot be cancelled into a second ending.
            settled_id = client.send_request("agent.cancel", {"invocationRef": "cancel-me"})
            settled = client.wait_response(settled_id)["result"]
            self.assertEqual(settled["outcome"], "unknown")
            self.assertEqual(
                sum(
                    candidate.get("method") == "agent.event"
                    and candidate["params"]["invocationRef"] == "cancel-me"
                    and candidate["params"]["kind"] == "terminal"
                    for candidate in client.frames
                ),
                1,
                "an invocation ended twice",
            )

    def test_observe_and_resume_replay_the_recorded_stream_after_a_cursor(self):
        with session() as client:
            client.initialize()
            client.execute("resume-me", "abcdefghij")
            original = client.events_for("resume-me")
            self.assertEqual(original[-1]["kind"], "terminal")

            resume_id = client.send_request(
                "agent.resume", {"priorInvocationRef": "resume-me", "cursor": ""}
            )
            receipt = client.wait_response(resume_id)["result"]
            self.assertEqual(receipt["priorInvocationRef"], "resume-me")
            self.assertEqual(receipt["replayedCount"], len(original))
            replayed = collect_events(client, "resume-me", receipt["replayedCount"])
            self.assertEqual([event["kind"] for event in replayed],
                             [event["kind"] for event in original])
            self.assertEqual(
                [event["sequence"] for event in replayed],
                [event["sequence"] for event in original],
                "replay keeps the recorded identity of every event",
            )

            cursor = str(original[0]["sequence"])
            observe_id = client.send_request(
                "agent.observe", {"priorInvocationRef": "resume-me", "cursor": cursor}
            )
            partial = client.wait_response(observe_id)["result"]
            remaining = collect_events(client, "resume-me", partial["replayedCount"])
            self.assertEqual(
                [event["sequence"] for event in remaining],
                [event["sequence"] for event in original[1:]],
            )

    def test_resume_without_prior_work_is_refused_not_invented(self):
        with session() as client:
            client.initialize()
            unknown_id = client.send_request(
                "agent.resume", {"priorInvocationRef": "never-seen", "cursor": ""}
            )
            unknown = client.wait_error(unknown_id)
            self.assertEqual(unknown["error"]["code"], -32004)
            self.assertEqual(unknown["error"]["message"], "unknown_prior_invocation")

            empty_id = client.send_request(
                "agent.resume", {"priorInvocationRef": "", "cursor": ""}
            )
            empty = client.wait_error(empty_id)
            self.assertEqual(empty["error"]["code"], -32602)
            self.assertEqual(
                empty["error"]["message"], "agent_resume_requires_prior_invocation"
            )

    def test_history_models_and_reconcile_are_read_only_and_do_not_block(self):
        with session() as client:
            client.initialize()
            client.execute("listed-1", "one")
            client.events_for("listed-1")

            history = client.request("agent.history", {"cursor": "", "limit": 10})["result"]
            self.assertEqual(len(history["items"]), 1)
            self.assertEqual(history["items"][0]["invocationRef"], "listed-1")
            self.assertTrue(history["items"][0]["terminal"])
            self.assertEqual(history["nextCursor"], "")

            models = client.request("agent.models")["result"]
            self.assertTrue(models["models"])
            self.assertTrue(all("modelId" in model for model in models["models"]))

            known = client.request(
                "agent.reconcile", {"invocationRef": "listed-1"}
            )["result"]
            self.assertEqual(known["outcome"], "known")
            self.assertEqual(known["terminal"]["outcome"], "succeeded")

            unknown = client.request(
                "agent.reconcile", {"invocationRef": "never-seen"}
            )["result"]
            self.assertEqual(unknown["outcome"], "unknown")

            # Read-only surfaces never block ordinary execution.
            self.assertEqual(client.execute("listed-2", "two")["outcome"], "accepted")
            self.assertEqual(client.events_for("listed-2")[-1]["kind"], "terminal")

    def test_usage_is_reported_without_inventing_unknowns(self):
        with session() as client:
            client.initialize()
            client.execute("usage-1", "hello")
            client.events_for("usage-1")
            observation = client.wait_method("usage.publish")["params"]
            self.assertEqual(observation["schema"], "licoup.usage-observation.v1")
            self.assertEqual(observation["scopeRef"], "usage-1")
            self.assertEqual(observation["operation"], "upsert")
            self.assertEqual(observation["revision"], 1)
            self.assertTrue(observation["observationId"])
            self.assertTrue(observation["sourceEpoch"])
            self.assertEqual(observation["observedAt"], "2026-01-01T00:00:00Z")
            items = observation["metrics"]["dev.example.agent/items"]
            self.assertEqual(items["quality"], "reported")
            self.assertEqual(items["value"], "1")
            tokens = observation["metrics"]["dev.example.agent/tokens"]
            self.assertEqual(tokens["quality"], "unknown")
            self.assertNotIn(
                "value", tokens, "an unknown metric carries no number, not a zero"
            )
            # A payload may not assert its own source binding.
            for forbidden in ("source", "extensionId", "instanceId", "generation"):
                self.assertNotIn(forbidden, observation)

    def test_the_recorded_session_replays_byte_for_byte(self):
        stdout, stderr, returncode = replay(
            [sys.executable, "-B", str(AGENT)], SAMPLE_DIR / "transcript.jsonl"
        )
        self.assertEqual(returncode, 0, stderr.decode("utf-8", errors="replace"))
        self.assertEqual(stdout, (SAMPLE_DIR / "events.jsonl").read_bytes())


if __name__ == "__main__":
    unittest.main()
