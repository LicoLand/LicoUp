#!/usr/bin/env python3
"""A full Agent: the required methods plus every optional ability it can honour.

It demonstrates the other end of the capability range without pretending to
more than it can do:

- `agent.cancel` is implemented and answers `acknowledged` only after the
  invocation's own terminal event says the work stopped.
- `agent.observe`/`agent.resume` replay a recorded stream after a cursor. They
  never re-send the same task as if it were a continuation.
- `agent.history` and `agent.models` are read-only and never block execution.
- Usage is reported, as one C11 observation with a synthetic value: this sample
  runs no model, so it reports the items it processed and leaves tokens unknown
  rather than inventing a zero. A real Agent reports what it measured.

The records live in this process only. Resuming an invocation this process
never saw is refused as unknown rather than reconstructed.

Replay the recorded session with:

    python3 -B agent.py < transcript.jsonl
"""
from __future__ import annotations

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "python"))

from licoup_agent_sdk import (
    Agent,
    Carrier,
    Invalid,
    UnknownPrior,
    usage_observation,
)

#: This sample records no wall-clock time. A synthetic observation carries a
#: fixed timestamp so a replayed session is byte-for-byte reproducible; a real
#: Agent reports the time it actually observed.
SYNTHETIC_OBSERVED_AT = "2026-01-01T00:00:00Z"
SOURCE_EPOCH = "dev.example.agent.sdk-full/session-1"

#: How many finished invocations stay resumable in memory.
RECORDED_INVOCATIONS = 8


class FullAgent(Agent):
    id = "dev.example.agent.sdk.full"
    capabilities = ("dev.example.agent/stream", "dev.example.agent/resume")
    instance_kind = "executable"
    interface_version = "1.0.0"
    usage = "reported"
    cancel = "supported"
    resume = "supported"
    profiles = ("agent-execution", "usage-metric")

    CHUNK_CHARS = 16
    STEP_SECONDS = 0.005

    def __init__(self) -> None:
        # invocation ref -> [(sequence, kind, body)], in emission order
        self._records: dict[str, list[tuple[int, str, object]]] = {}
        self._order: list[str] = []

    # --- execution ----------------------------------------------------------

    def run(self, invocation, emit) -> None:
        record = self._records.setdefault(invocation.reference, [])
        try:
            text = invocation.text
            pieces = [
                text[index : index + self.CHUNK_CHARS]
                for index in range(0, len(text), self.CHUNK_CHARS)
            ] or [""]
            for piece in pieces:
                if invocation.is_cancelled():
                    self._emit_and_record(emit, record, invocation, "terminal", {
                        "outcome": "cancelled",
                    })
                    return
                self._emit_and_record(emit, record, invocation, "text", piece)
                time.sleep(self.STEP_SECONDS)
            self._emit_and_record(emit, record, invocation, "terminal", {
                "outcome": "succeeded",
            })
            # C11: report what was actually produced. Items are counted; tokens
            # are unknown, because this sample runs no model and a zero would
            # be a claim that nothing happened.
            emit.usage(
                usage_observation(
                    scope_ref=invocation.reference,
                    observation_id=f"{invocation.reference}/items"[:160],
                    source_epoch=SOURCE_EPOCH,
                    observed_at=SYNTHETIC_OBSERVED_AT,
                    metrics={
                        "dev.example.agent/items": {
                            "value": "1",
                            "unit": "items",
                            "temporality": "delta",
                            "quality": "reported",
                        },
                        "dev.example.agent/tokens": {
                            "unit": "tokens",
                            "temporality": "delta",
                            "quality": "unknown",
                        },
                    },
                )
            )
        finally:
            self._remember_order(invocation.reference)

    def _emit_and_record(self, emit, record, invocation, kind, body) -> None:
        if kind == "text":
            emit.text(body)
        else:
            emit.terminal(body)
        # The piece sizes here stay far below any negotiated bound, so one call
        # is one frame and `emit.sequence` identifies it exactly.
        record.append((emit.sequence, kind, body))

    def _remember_order(self, reference: str) -> None:
        if reference in self._order:
            return
        self._order.append(reference)
        while len(self._order) > RECORDED_INVOCATIONS:
            oldest = self._order.pop(0)
            self._records.pop(oldest, None)

    # --- optional abilities -------------------------------------------------

    def cancel_request(self, invocation):
        if invocation is None:
            return "unknown"
        if invocation.finished:
            # The named work already ended; a cancel changed nothing.
            return "unknown"
        if invocation.is_cancelled():
            return "acknowledged"
        invocation.cancelled.set()
        # Wait for the work's own terminal event: only the extension knows
        # whether it actually stopped, and `acknowledged` claims it did.
        if invocation.wait_finished(timeout=2.0):
            return "acknowledged"
        return "requested"

    def replay(self, prior_ref: str, cursor: str):
        record = self._records.get(prior_ref)
        if record is None:
            raise UnknownPrior("unknown_prior_invocation")
        if cursor == "":
            last_seen = 0
        elif cursor.isdigit():
            last_seen = int(cursor)
        else:
            raise Invalid("invalid_cursor")
        events = [event for event in record if event[0] > last_seen]
        receipt = {
            "priorInvocationRef": prior_ref,
            "replayedCount": len(events),
            "nextCursor": str(record[-1][0]) if record else "0",
        }
        return receipt, events

    def history(self, cursor: str, limit: int) -> dict:
        if cursor == "":
            offset = 0
        elif cursor.isdigit():
            offset = int(cursor)
        else:
            raise Invalid("invalid_cursor")
        page = self._order[offset : offset + limit]
        records = [
            {
                "invocationRef": reference,
                "events": len(self._records.get(reference, [])),
                "terminal": any(
                    kind == "terminal"
                    for _, kind, _ in self._records.get(reference, [])
                ),
            }
            for reference in page
        ]
        next_offset = offset + len(page)
        return {
            "items": records,
            "nextCursor": str(next_offset) if next_offset < len(self._order) else "",
        }

    def models(self) -> dict:
        return {
            "models": [
                {
                    "modelId": "dev.example.agent/local-echo",
                    "displayName": "Local Echo",
                    "capabilities": ["dev.example.agent/text"],
                }
            ]
        }

    def reconcile(self, invocation_ref: str) -> dict:
        record = self._records.get(invocation_ref)
        if record is None:
            # No record of this effect: the result stays unknown.
            return {"invocationRef": invocation_ref, "outcome": "unknown"}
        terminal = next(
            (body for _, kind, body in record if kind == "terminal"), None
        )
        return {
            "invocationRef": invocation_ref,
            "outcome": "known",
            "terminal": terminal,
            "eventCount": len(record),
        }


if __name__ == "__main__":
    raise SystemExit(Carrier(FullAgent()).serve())
