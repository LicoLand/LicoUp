# v7.1 Agent SDK component suite

Updated: 2026-09-25

Every case here starts a real local process: an SDK sample, the generic carrier
with a wrapped command, or the compiled native sample. They assert observable
wire behavior — frames, bounds, receipts, events, refusals — not internal
functions. No model, network, credential or external service is involved.

| File | Covers |
|:---|:---|
| `harness.py` | A reference host-side client: start, handshake, bounded frame reading, request/response matching, event collection, byte-for-byte replay |
| `test_minimal_specialist.py` | The minimal complete Agent: verbatim replies (plain, JSON-looking, unicode, empty), duplicates, truthful refusals, bounds, framing faults, malformed ids, recorded replay |
| `test_full_agent.py` | Capability difference: negotiated cancel/resume/usage, cancel acknowledged only after the work stopped, observe/resume replay with cursors, history/models/reconcile, a C11 observation that keeps unknown values unknown |
| `test_native_executable.py` | The same contract compiled from C: build, handshake, escaping, unicode, duplicates, bounds, framing faults, a legal id echoed in full at the answerability limit, invalid/non-finite/over-limit ids refused without reflection, references with quotes and backslashes, recorded replay |
| `test_generic_carrier.py` | The descriptor path: wrapping a real CLI, strict descriptor refusals, unsupported cancel, terminating a running command, 2000-line bulk bounded and complete, cancel answered while bulk flows, recorded replay |
| `test_sdk_framing.py` | The SDK's framing promises without a process: chunking, reassembly, sequence monotonicity, nothing after terminal, bounded refusal path |
| `test_wire_parity.py` | The SDK against the frozen contract crate: bounds, profile major, published method names, wire ids, and the sample manifests against the published schema |

## Running it

```bash
python3 -B tests/integration/agent_sdk/run_tests.py
```

Single files, for focused work:

```bash
python3 -B -m unittest discover -s tests/integration/agent_sdk -p "test_full_agent.py" -v
python3 -B -m unittest discover -s tests/integration/agent_sdk -p "test_generic_carrier.py" -v
```

Through the repository toolchain wrapper (this is what a regression module
should use):

```bash
node tools/scripts/client-toolchain-runner.mjs -- python3 -B tests/integration/agent_sdk/run_tests.py
```

The native-executable cases need `cc`. That compiler is already required to
link the repository's Rust build; where it is absent the native cases report
themselves as skipped with that reason, and the remaining carriers still run.

## Catalog registration

The suite is one module. The inputs are the SDK, the carrier and the tests:

```
id: regression.v71-agent-sdk
kind: regression-infrastructure
summary: "Language-agnostic extension.v1 Agent adapters: samples, generic CLI carrier, bounds and replay"
inputs:
  - sdk/agent-adapter/**
  - extensions/generic/**
  - tests/integration/agent_sdk/**
command: node tools/scripts/client-toolchain-runner.mjs -- python3 -B tests/integration/agent_sdk/run_tests.py
```

## What this level does and does not prove

Component integration: a new namespaced Agent, a wrapped CLI and a compiled
binary all serve the same published contract over a real pipe, with no core
crate change, no vendor switch and no forced reply format; unsupported optional
abilities are negotiated instead of faked; bulk output stays bounded while
control frames are still answered.

Not proven here: installation into a running client, process isolation and
quotas, registry epochs and generation switching, and the installed-product
acceptance those belong to. Those are other tasks' scopes; this suite never
claims them.
