# ADR-0001: PTY transport for the Antigravity and Cursor CLI lanes

Updated: 2026-09-25

Status: implemented · Authority: code and the driver registry own current facts

## Context

LicoUp converses with Agent CLIs through per-Agent drivers sharing the `execute`
shape under `crates/licoup-native/src/platform/*_driver/`. Antigravity and Cursor
need terminal semantics while retaining their own output protocols, bounded
streaming, cancellation, and terminal-result behavior.

## Decision

Introduce a shared unix-only PTY foundation `pty_transport.rs` and use it for
the Antigravity and Cursor turn lanes:

1. **Zero new dependencies**: raw `libc` FFI (`openpty`, `cfmakeraw`,
   `tcgetattr`/`tcsetattr`, `TIOCSWINSZ`) — `libc 0.2` is already a dependency.
2. **stdin+stdout on the pty slave, stderr stays a real pipe**. The slave runs
   in raw mode (OPOST off), so `\n` is not translated to `\r\n` and structured
   line-based protocols parse byte-identically to pipes. A piped stderr keeps
   driver stderr-counting semantics intact and keeps stderr noise out of the
   stdout protocol stream.
3. **`spawn(command: Command)` takes the command by value and drops it before
   returning**: `std` keeps `Stdio::from(OwnedFd)` descriptors open in the
   parent until the `Command` drops, and a parent-held slave fd would keep the
   master from reaching EOF/EIO when the child exits (every turn would stall
   until timeout).
4. **`Master::read` translates Linux's EIO (all slaves closed) into a clean
   EOF** and retries EINTR, so natural child exits close the stream instead of
   surfacing as read errors (macOS returns EOF natively).
5. **Reader thread with a bounded event protocol**: `Data` / `Truncated` /
   `Closed`. On exceeding the byte cap the allowed prefix is delivered, then
   reads continue discarding until EOF — truncate-and-succeed without letting a
   chatty child block on the PTY buffer.
6. **Incremental ANSI stripper for the Antigravity lane**: CSI / OSC / DCS /
   single-char escapes and CR bytes are dropped; cursor movement is not
   interpreted (the `--print` output contract is sequential text). Escape
   sequences and multibyte UTF-8 may span read boundaries; the concatenated
   output is byte-exact.
7. **Antigravity** now emits `agent.turn.accepted` at start and
   `agent.message.chunk` progressively from the pty stream; `timeout_ms == 0`
   now means "no deadline", matching Cursor/Claude Code and the dispatch
   contract. Auth gate, hook receipt, and
   session resume mechanics are unchanged.
8. **Cursor** keeps its NDJSON parser unchanged (`read_protocol_messages`);
   only the turn subprocess spawn moves to the pty. `create-chat` session
   bootstrap stays on pipes.
9. **Non-unix platforms use the pipe implementation** selected by the driver's
   `cfg` variant.
10. **Registry**: `agent-conversation-drivers.json` flips Antigravity's
    `capabilityMatrix.streaming` to `true` and `lifecycleEvidence.accepted` /
    `responding` to `true`. `processing` intentionally stays `false` — every
    driver with `processing: true` emits `agent.turn.processing` evidence;
    Antigravity emits accepted + chunks + completed, so flipping it would be an
    unbacked claim. Readiness status remains `unverified`.

## Alternatives considered

- **`portable-pty` crate** — mature, cross-platform (Unix ptmx + Windows
  ConPTY), used by WezTerm. Rejected: new dependency, and its async API does
  not match the crate's synchronous dispatch threads.
- **`nix::pty` (`openpty`/`forkpty`)** — would require enabling the `nix`
  "term" feature. Rejected under the zero-new-dependencies rule when raw
  `libc` is already available.
- **Full terminal emulator** (cursor movement, scrollback, alternate screens) —
  unnecessary for sequential `--print` text; the stripper contract covers the
  current lanes.
- **Controlling terminal session (`setsid` + `TIOCSCTTY`)** — not used by the
  current `--print` lanes. PTY-generated job-control signals therefore do not
  reach the child; cancellation uses process-group SIGTERM (`control.rs`).
- **Windows ConPTY** — not used by this implementation; the current non-unix
  driver variant uses pipes.

## Rationale

The driver contract (`execute(...) -> RunResult` + the thread-local stream sink
in `turn_event_emit.rs`) required no signature change: the pty lane consumes
the master in a reader thread, emits progressive chunks on the dispatch thread,
and returns the same `RunResult`. The Dart conversation surface renders chunk
events by `participantAgentId` and tolerates empty `sessionId`, so new-session
chunks (which cannot carry a native session id until the hook receipt is
written at exit) render correctly. A unix-first foundation with a piped
fallback keeps the change bounded and reviewable.

## Consequences

- Antigravity conversations stream progressively on Unix.
- Chunk events carry the *requested* session id, which is empty for a new
  session; the terminal response carries the native session id.
- `agent.message.completed` is sink-emitted on unix in addition to the
  post-hoc events envelope; the Dart controller fills final text from
  `dispatch.turn.completed` only when no streamed text exists, so there is no
  double render.
- Output beyond the byte cap uses truncate-and-succeed on Unix.
- Non-unix behavior is unchanged.

## Current authorities

`crates/licoup-native/src/platform/pty_transport.rs` owns the PTY behavior.
The Antigravity and Cursor drivers own their process and parsing adaptations;
`resources/agent-conversation-drivers.json` owns declared driver capabilities.
