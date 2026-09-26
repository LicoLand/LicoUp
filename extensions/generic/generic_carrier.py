#!/usr/bin/env python3
"""Shared generic carrier: run an ordinary CLI as an Agent through extension.v1.

A user who already has a command-line program does not have to modify it, and
does not have to write a protocol implementation, to use it as an Agent. This
carrier reads one strict descriptor (data, not code), starts the named command
once per invocation, turns its standard output into `agent.event` text frames,
its standard error into bounded diagnostics, and its exit status into the
terminal event. Nothing here is vendor-specific: the command, its arguments and
the capability names come from the descriptor, and there is no vendor switch.

The descriptor:
- `command` is an argv array. There is no shell, no template, no `eval`, and no
  command substitution: an argument is a string, never a program to build.
- `input` is `stdin-text` (the invocation input is written to the child's
  standard input) or `none`.
- `output` is `stdout-lines`: every line is carried with its newline, so the
  host receives the child's stream as it was written.
- `terminal` is `exit-code`: exit 0 succeeded, a non-zero exit failed, a signal
  failed with the signal named, and a cancellation the carrier requested is
  cancelled.
- `cancel` is `terminate` or `unsupported`. `unsupported` is a complete answer:
  basic execution and events are still served.
- The descriptor cannot set environment variables. The host decides what
  environment the extension process gets, and secrets are not configuration.

Run it with the descriptor path, or with `descriptor.json` next to this file:

    python3 -B generic_carrier.py /path/to/descriptor.json
"""
from __future__ import annotations

import json
import os
import subprocess
import sys
import threading
from pathlib import Path

# The SDK travels with this file: copy both, or keep the repository layout.
_SDK_CANDIDATES = (
    Path(__file__).resolve().parent,
    Path(__file__).resolve().parents[2] / "sdk" / "agent-adapter" / "python",
)
for _candidate in _SDK_CANDIDATES:
    if (_candidate / "licoup_agent_sdk.py").is_file():
        sys.path.insert(0, str(_candidate))
        break

try:
    from licoup_agent_sdk import Agent, Carrier, is_namespaced, log
except ImportError as _error:  # pragma: no cover - configuration mistake
    sys.stderr.write(
        "generic carrier requires licoup_agent_sdk.py in the same directory "
        f"or in the repository SDK path: {_error}\n"
    )
    raise SystemExit(2)

DESCRIPTOR_SCHEMA = "licoup.generic-adapter.v1"

_REQUIRED_KEYS = (
    "schema",
    "id",
    "displayName",
    "command",
    "input",
    "output",
    "terminal",
    "cancel",
    "capabilities",
)
_ALLOWED_KEYS = frozenset(_REQUIRED_KEYS) | {"cwd"}

_INPUT_MODES = ("stdin-text", "none")
_OUTPUT_MODES = ("stdout-lines",)
_TERMINAL_MODES = ("exit-code",)
_CANCEL_MODES = ("terminate", "unsupported")


class DescriptorError(Exception):
    """The descriptor is not one this carrier will execute."""


def load_descriptor(path: Path) -> dict:
    """Read and strictly validate one descriptor.

    Unknown keys are refused rather than ignored: a descriptor is what decides
    which program runs, and a key this carrier does not understand might have
    been meant as a permission, a mapping or an environment change.
    """
    try:
        raw = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise DescriptorError(f"descriptor_unreadable: {error}") from error
    if not isinstance(raw, dict):
        raise DescriptorError("descriptor_not_an_object")
    unknown = sorted(set(raw) - _ALLOWED_KEYS)
    if unknown:
        raise DescriptorError(f"descriptor_unknown_fields: {','.join(unknown)}")
    missing = [key for key in _REQUIRED_KEYS if key not in raw]
    if missing:
        raise DescriptorError(f"descriptor_missing_fields: {','.join(missing)}")
    if raw["schema"] != DESCRIPTOR_SCHEMA:
        raise DescriptorError("descriptor_schema_mismatch")
    if not isinstance(raw["id"], str) or not is_namespaced(raw["id"]):
        raise DescriptorError("descriptor_id_invalid")
    if not isinstance(raw["displayName"], str) or not raw["displayName"]:
        raise DescriptorError("descriptor_display_name_invalid")
    command = raw["command"]
    if (
        not isinstance(command, list)
        or not command
        or not all(isinstance(item, str) and item and "\x00" not in item for item in command)
    ):
        raise DescriptorError("descriptor_command_invalid")
    if raw["input"] not in _INPUT_MODES:
        raise DescriptorError("descriptor_input_invalid")
    if raw["output"] not in _OUTPUT_MODES:
        raise DescriptorError("descriptor_output_invalid")
    if raw["terminal"] not in _TERMINAL_MODES:
        raise DescriptorError("descriptor_terminal_invalid")
    if raw["cancel"] not in _CANCEL_MODES:
        raise DescriptorError("descriptor_cancel_invalid")
    capabilities = raw["capabilities"]
    if (
        not isinstance(capabilities, list)
        or not capabilities
        or not all(isinstance(item, str) and is_namespaced(item) for item in capabilities)
    ):
        raise DescriptorError("descriptor_capabilities_invalid")
    if "cwd" in raw and (not isinstance(raw["cwd"], str) or not raw["cwd"]):
        raise DescriptorError("descriptor_cwd_invalid")
    return raw


def _decode_output(raw: bytes) -> tuple[str, bool]:
    """Decode child output as UTF-8; report a replacement instead of hiding it."""
    try:
        return raw.decode("utf-8"), False
    except UnicodeDecodeError:
        return raw.decode("utf-8", errors="replace"), True


class CliAdapter(Agent):
    """One descriptor, carried as an Agent."""

    usage = "unavailable"
    resume = "unsupported"

    def __init__(self, descriptor: dict, base_dir: Path) -> None:
        self.descriptor = descriptor
        self.id = descriptor["id"]
        self.instance_kind = "cli-adapter"
        self.capabilities = tuple(descriptor["capabilities"])
        self.input_mode = descriptor["input"]
        self.cancel = "supported" if descriptor["cancel"] == "terminate" else "unsupported"
        self._command = list(descriptor["command"])
        raw_cwd = descriptor.get("cwd", ".")
        cwd = Path(raw_cwd)
        self._cwd = (base_dir / cwd).resolve() if not cwd.is_absolute() else cwd
        self._replacement_logged: set[str] = set()

    # --- execution ----------------------------------------------------------

    def run(self, invocation, emit) -> None:
        child = None
        try:
            child = subprocess.Popen(  # noqa: S603 - the descriptor is the user's explicit target
                self._command,
                cwd=str(self._cwd),
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
        except OSError as error:
            log(f"cli_adapter_command_not_started: {error}")
            emit.terminal({"outcome": "failed", "reason": "command_not_started"})
            return
        invocation.state["child"] = child
        input_thread = threading.Thread(
            target=self._write_input, args=(child, invocation), daemon=True
        )
        input_thread.start()
        errors_thread = threading.Thread(
            target=self._pump_diagnostics, args=(child, invocation), daemon=True
        )
        errors_thread.start()
        try:
            self._stream_output(child, invocation, emit)
        finally:
            returncode = child.wait()
            if invocation.is_cancelled():
                emit.terminal({"outcome": "cancelled"})
            elif returncode == 0:
                emit.terminal({"outcome": "succeeded"})
            elif returncode < 0:
                emit.terminal({"outcome": "failed", "signal": -returncode})
            else:
                emit.terminal({"outcome": "failed", "exitCode": returncode})

    def _write_input(self, child, invocation) -> None:
        try:
            if self.input_mode == "stdin-text" and invocation.text:
                child.stdin.write(invocation.text.encode("utf-8"))
            child.stdin.close()
        except (BrokenPipeError, OSError, ValueError):
            # The command did not read its input; that is the command's choice.
            pass

    def _pump_diagnostics(self, child, invocation) -> None:
        try:
            while True:
                line = child.stderr.readline(8192)
                if not line:
                    return
                decoded, replaced = _decode_output(line)
                if replaced:
                    log("cli_adapter_non_utf8_diagnostic")
                log(f"cli[{invocation.reference}]: {decoded.rstrip()}")
        except (OSError, ValueError):
            return

    def _stream_output(self, child, invocation, emit) -> None:
        buffer = bytearray()
        limit = emit.max_frame_bytes
        # `os.read` returns as soon as some bytes are available; a buffered
        # `read(n)` would wait for the full n bytes and hold a trickling program's
        # output until it exited.
        descriptor = child.stdout.fileno()
        while True:
            chunk = os.read(descriptor, 65536)
            if not chunk:
                break
            buffer.extend(chunk)
            while True:
                newline = buffer.find(b"\n")
                if newline < 0:
                    if len(buffer) >= limit:
                        # A single line longer than the frame bound is streamed
                        # in chunks; memory stays bounded and the frame bound is
                        # never exceeded.
                        self._emit_text(emit, invocation, bytes(buffer))
                        buffer.clear()
                    break
                line = bytes(buffer[: newline + 1])
                del buffer[: newline + 1]
                self._emit_text(emit, invocation, line)
        if buffer:
            self._emit_text(emit, invocation, bytes(buffer))

    def _emit_text(self, emit, invocation, raw: bytes) -> None:
        decoded, replaced = _decode_output(raw)
        if replaced and invocation.reference not in self._replacement_logged:
            self._replacement_logged.add(invocation.reference)
            log("cli_adapter_non_utf8_output")
        emit.text(decoded)

    # --- optional ability ---------------------------------------------------

    def cancel_request(self, invocation):
        if invocation is None:
            return "unknown"
        if invocation.finished:
            return "unknown"
        if invocation.is_cancelled():
            return "acknowledged"
        invocation.cancelled.set()
        child = invocation.state.get("child")
        if child is not None and child.poll() is None:
            self._terminate(child)
        # Only the child's own end says the work stopped.
        if invocation.wait_finished(timeout=2.0):
            return "acknowledged"
        return "requested"

    @staticmethod
    def _terminate(child) -> None:
        try:
            child.terminate()
        except OSError:
            return
        try:
            child.wait(timeout=2.0)
            return
        except subprocess.TimeoutExpired:
            pass
        try:
            child.kill()
        except OSError:
            return
        try:
            child.wait(timeout=2.0)
        except subprocess.TimeoutExpired:
            log("cli_adapter_child_did_not_exit")


def main(argv: list[str]) -> int:
    base_dir = Path(__file__).resolve().parent
    if argv:
        descriptor_path = Path(argv[0])
        if not descriptor_path.is_absolute():
            descriptor_path = (Path.cwd() / descriptor_path).resolve()
    else:
        descriptor_path = base_dir / "descriptor.json"
    try:
        descriptor = load_descriptor(descriptor_path)
    except DescriptorError as error:
        sys.stderr.write(f"generic_carrier: {error}\n")
        return 2
    agent = CliAdapter(descriptor, descriptor_path.resolve().parent)
    return Carrier(agent).serve()


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
