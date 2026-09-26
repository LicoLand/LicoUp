# Agent adapter SDK

Updated: 2026-09-25

An Agent in LicoUp is an ordinary program. The contract is one JSON object per
line on `stdout`, diagnostics on bounded `stderr`, and one wire protocol —
`extension.v1`. Nothing about it is Rust-specific and no runtime is required.
This directory holds a reference carrier and three samples in two languages that
prove it.

| Path | What it is |
|:---|:---|
| `python/licoup_agent_sdk.py` | A stdlib-only reference carrier: framing, bounds, request ids, chunking, sequences, admission receipts, terminal events and honest optional-method dispatch |
| `samples/minimal-specialist/` | The smallest complete Agent: handshake plus `agent.describe`, `agent.execute`, `agent.event`; every optional ability declared unsupported |
| `samples/full-agent/` | The other end of the range: `agent.cancel`, `agent.observe`/`agent.resume`, `agent.history`, `agent.models`, `agent.reconcile`, and usage reported through C11 |
| `samples/native-executable/` | The same minimal contract as a compiled C program with no runtime and no dependency (`cc -std=c11 -O2 -Wall -Wextra -o agent agent.c`) |

The normative contract lives in
[`crates/licoup-extension-contracts/`](../../crates/licoup-extension-contracts)
and [`docs/architecture/EXTENSION-PLATFORM.md`](../../docs/architecture/EXTENSION-PLATFORM.md);
the samples here are checked against it, not a second version of it. The
component suite in
[`tests/integration/v71_agent_sdk/`](../../tests/integration/v71_agent_sdk)
starts every sample as a real subprocess and asserts the wire behavior, and
`test_wire_parity.py` reads the contract crate and fails if a bound, a version
or a method name drifts.

## Writing an Agent

```python
from licoup_agent_sdk import Agent, Carrier

class MyAgent(Agent):
    id = "vendor.example.my-agent"          # namespaced: no core change is needed
    capabilities = ("vendor.example/stream",)

    def run(self, invocation, emit):
        emit.text("hello " + invocation.text)   # verbatim; never parsed
        emit.terminal({"outcome": "succeeded"}) # the only end-of-work fact

raise SystemExit(Carrier(MyAgent()).serve())
```

Only `run` is required. An optional ability is enabled by setting the attribute
(`cancel = "supported"`, `resume = "supported"`, `usage = "reported"`) and
implementing the matching hook; leaving it out is a complete answer. The carrier
enforces the rules an author would otherwise have to remember:

- the frame bound and chunking of long text,
- monotone per-invocation sequence numbers and "nothing after terminal",
- request id validation,
- duplicate submission without re-execution,
- `extension.shutdown` waited until admitted work reaches its terminal event.

## The wire

Requests arrive from the host; results answer them; `agent.event` frames are
notifications. A frame is one line; `stdout` carries the protocol and nothing
else. The `initialize` result negotiates `maxFrameBytes` as the smaller of the
two sides, in the accepted range 4 KiB to 8 MiB (default 64 KiB). Diagnostics
are on `stderr`, bounded to 8 KiB per line. `agent.execute` reports admission,
never completion; a terminal *event* is the only end-of-work fact. An invocation
reference is at most 160 UTF-8 bytes.

A request id is echoed verbatim — a valid JSON string, a JSON number, or `null`
— whenever a response that carries it fits the negotiated bound. A legal id is
never shortened, emptied or truncated to fit; an id that cannot be echoed as
valid JSON (`Infinity`, `NaN`, a malformed number, a raw control byte, an
object, an array, a boolean) or cannot fit the bound is answered with a bounded
`-32001` error whose id is `null`, reflecting neither the id nor the request
content. An invocation reference is escaped the same way: a reference
containing quotes or backslashes still produces valid JSON.

The method catalogs are published in
[`crates/licoup-extension-contracts/src/profile.rs`](../../crates/licoup-extension-contracts/src/profile.rs);
the wire envelopes are demonstrated by the samples and asserted by the
component suite. The one rule that matters most for interoperability is not a
shape: **an extension never invents support it does not have.**

| Situation | Honest answer |
|:---|:---|
| No cancel | `agent.describe` says `cancel: "unsupported"`; `agent.cancel` answers `-32601`. Execution and events are unaffected |
| No resume | `resume: "unsupported"`; an invocation cannot be reconstructed, so no stream is invented |
| No usage | `usage: "unavailable"`; the host records no zeros on the extension's behalf |
| Work already ended | `agent.cancel` answers `unknown`, not `acknowledged`: the request changed nothing |
| Handler returns without a terminal event | The carrier reports terminal `{"outcome": "unknown"}` rather than leaving silence that reads as success |

## The work-context mapping

The host maps its own work-context operations onto this wire; an adapter author
never sees conversation identity, membership or generation. The mapping the host
applies is:

| Work-context fact | Wire fact |
|:---|:---|
| An admitted turn (`host_handle`, `native_turn_id`) | `agent.execute` with `invocationRef` and verbatim `input` |
| Turn output, reasoning or tool text | `agent.event` kind `text`; body carried verbatim |
| Turn exit Completed / Failed / Cancelled / Eof / Disconnected | Terminal event body `{"outcome": "succeeded" / "failed" / "cancelled" / "unknown"}` |
| `NativeControlIntent::Cancel(host_handle, native_turn_id)` | `agent.cancel`; `requested`, `acknowledged`, `unsupported` and `unknown` stay four separate facts, and none of them withdraws an external effect |
| Exact resume of a session (`session_presence`) | `agent.resume` with `priorInvocationRef` and a cursor; a native session is not a Conversation identity |
| Steer content | `agent.steer` — only where the Agent really supports it |
| Work-context reconciliation of an effect | `agent.reconcile`; without native support the result stays Unknown |
| Capability snapshot (`exact_resume`, `cancel`) | `agent.describe`; a missing ability refuses only its own operation |

The SDK carries no host identity and asserts no authority: there is no
`principal`, `effectId`, `authorized` or `stateRoot` anywhere in a frame, and a
payload that offered one would not be an extension with more rights.

## Replayable fixtures

Each sample carries a recorded session: `transcript.jsonl` is the input frames,
`events.jsonl` is the exact output that session produced. Replay is
byte-for-byte:

```bash
python3 -B samples/minimal-specialist/agent.py < samples/minimal-specialist/transcript.jsonl
python3 -B samples/full-agent/agent.py       < samples/full-agent/transcript.jsonl
cc -std=c11 -O2 -Wall -Wextra -o /tmp/licoup-agent samples/native-executable/agent.c \
  && /tmp/licoup-agent < samples/native-executable/transcript.jsonl
```

The sessions are deterministic by construction: shutdown waits for admitted
work, so the recorded order does not depend on thread scheduling.

## Conformance checklist for any language

1. One JSON object per line; `stdout` only protocol; `stderr` bounded.
2. Answer `extension.initialize` with the smaller frame bound and the served
   profiles, and send `extension.ready` when prepared.
3. Implement `agent.describe`, `agent.execute`, `agent.event` and the
   handshake. Everything else is optional.
4. Report admission, never completion; end the work with one terminal event.
5. Never emit a frame larger than the negotiated bound; split text.
6. Echo a legal request id in full inside a frame sized for it; never shorten,
   empty or truncate one. Refuse an oversize frame as a framing fault, an
   unknown method with `-32601`, a call before the handshake with `-32600`, and
   an id that cannot be echoed as valid JSON (`Infinity`, `NaN`, malformed
   number, raw control byte, object, array, boolean) or cannot fit the bound
   with `-32001` and no reflection.
7. Carry event bodies verbatim. A reply that looks like JSON is still a reply.
8. Declare absences in `agent.describe` and do not fake them.

## Not in this directory

No host, no catalog, no scheduler and no storage: those are the client's. No
model, network, credential or user data is touched by any sample; the usage
observation in the full sample is synthetic and fixed so its replay is exact.
