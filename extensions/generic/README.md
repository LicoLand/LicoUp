# Generic CLI carrier

Updated: 2026-09-25

A user who already has a command-line program does not have to modify it, and
does not have to write protocol code, to use it as an Agent. This package is the
shared carrier: it reads one strict descriptor, starts the named command once
per invocation, and speaks `extension.v1` to the client.

| File | What it is |
|:---|:---|
| `generic_carrier.py` | The shared carrier (stdlib only; it imports `licoup_agent_sdk.py` from the same directory or from `sdk/agent-adapter/python/`) |
| `descriptor.schema.json` | The descriptor format, also useful to a host-side declarative runtime |
| `descriptor.json` | The sample descriptor, wrapping `echo_cli.py` |
| `echo_cli.py` | A stand-in for a program that already existed: reads stdin, echoes each line, exits zero |
| `manifest.json` | The package manifest for this carrier |
| `transcript.jsonl`, `events.jsonl` | A recorded session for byte-for-byte replay |

There is no vendor switch anywhere in the carrier. The wrapped program, its
arguments and the advertised capability names come from the descriptor; a new
program is a new descriptor, not a new code path.

## The descriptor

```json
{
  "schema": "licoup.generic-adapter.v1",
  "id": "dev.example.agent.echo-cli",
  "displayName": "Echo CLI adapter",
  "command": ["python3", "-B", "echo_cli.py"],
  "input": "stdin-text",
  "output": "stdout-lines",
  "terminal": "exit-code",
  "cancel": "terminate",
  "capabilities": ["dev.example.agent/stream"],
  "cwd": "."
}
```

| Field | Meaning |
|:---|:---|
| `command` | An argv array: the program and its arguments. No shell, no templates, no `eval`, no command substitution |
| `input` | `stdin-text` writes the invocation input to the command's stdin and closes it; `none` closes it immediately |
| `output` | `stdout-lines`: every line is carried as a text event with its newline, so the host receives the stream as written. A line longer than the negotiated frame bound is split into bounded events |
| `terminal` | `exit-code`: exit 0 succeeded; non-zero failed with the code; a signal failed with the signal; a cancellation the carrier requested is cancelled |
| `cancel` | `terminate` (terminate, then kill after a grace period) or `unsupported`. `unsupported` is a complete answer: execution and events keep working |
| `capabilities` | Namespaced capabilities the adapter advertises |
| `cwd` | Optional working directory; relative paths resolve against the descriptor's directory. Defaults to the descriptor's directory |

Standard error is never protocol: it is copied to the carrier's own `stderr`
with a prefix and a bound, so a chatty program cannot corrupt the wire.

The descriptor cannot set environment variables. The host decides what
environment the extension process gets, and secrets are config and credential
handles, not adapter data. Unknown descriptor keys are refused rather than
ignored — a key the carrier does not understand might have been meant as a
permission.

## Running it

The package's manifest starts the carrier as a process. The descriptor is
`descriptor.json` next to the carrier, or the first argument:

```bash
python3 -B generic_carrier.py
python3 -B generic_carrier.py /path/to/descriptor.json
python3 -B generic_carrier.py descriptor.json < transcript.jsonl   # byte-for-byte replay
```

To reuse the carrier in another package, copy `generic_carrier.py` and
`licoup_agent_sdk.py` together and edit the descriptor.

## Bounds and control

`stdout` from the wrapped command is read in bounded chunks and split on line
boundaries, so a program that produces a lot of output cannot grow carrier
memory without limit, and every emitted frame stays inside the negotiated
bound. A cancel request is answered from the carrier's own read loop while the
command is still producing output; the child is terminated and the invocation
ends with a terminal `cancelled` event. Cancellation is a request: an effect the
command already produced outside this machine is not withdrawn, and the
carrier never claims otherwise.

## Component evidence

`tests/integration/v71_agent_sdk/test_generic_carrier.py` starts this carrier as
a real process and wraps a real child command: the sample mapping, strict
descriptor refusals, an unsupported cancel that leaves execution working, a
cancel that stops a running command, a 2000-line bulk stream bounded by a 4 KiB
negotiated bound, and a cancel answered while bulk output is flowing. No
network, model or external service is involved.
