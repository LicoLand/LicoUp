"""A reference host-side client for the component tests.

The tests drive real extension processes over a pipe: this module starts one,
writes JSON-RPC frames, reads frames back inside the negotiated bound, and keeps
the transcript so a test can assert on it. It is deliberately a client, not a
second implementation of the contract: it makes no decisions an extension
should make, and it never parses an event body.

Nothing here talks to a network or a model. Every session is a local child
process and synthetic input.
"""
from __future__ import annotations

import json
import queue
import subprocess
import sys
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]

DEFAULT_BOUND = 64 * 1024


class WireError(AssertionError):
    """The wire was not what the contract says it is."""


class Session:
    """One extension process, framed over stdin/stdout."""

    def __init__(
        self,
        argv,
        *,
        cwd: Path | str | None = None,
        bound: int = DEFAULT_BOUND,
        timeout: float = 15.0,
    ) -> None:
        self.argv = [str(argument) for argument in argv]
        self.cwd = str(cwd if cwd is not None else ROOT)
        self.bound = bound
        self.timeout = timeout
        self.process: subprocess.Popen | None = None
        self.raw_lines: list[bytes] = []
        self.frames: list[dict] = []
        self._queue: queue.Queue = queue.Queue()
        self._pending: list[dict] = []
        self._stderr = bytearray()
        self._stderr_lock = threading.Lock()
        self._stdout_reader: threading.Thread | None = None
        self._stderr_reader: threading.Thread | None = None
        self._next_id = 0
        self.initialize_response: dict | None = None
        self.ready: dict | None = None

    # --- lifecycle ----------------------------------------------------------

    def __enter__(self) -> "Session":
        return self.start()

    def __exit__(self, *_exc) -> None:
        self.close()

    def start(self) -> "Session":
        self.process = subprocess.Popen(
            self.argv,
            cwd=self.cwd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )
        self._stdout_reader = threading.Thread(target=self._read_stdout, daemon=True)
        self._stdout_reader.start()
        self._stderr_reader = threading.Thread(target=self._read_stderr, daemon=True)
        self._stderr_reader.start()
        return self

    def _read_stdout(self) -> None:
        assert self.process is not None and self.process.stdout is not None
        for raw in self.process.stdout:
            self.raw_lines.append(raw)
            stripped = raw.rstrip(b"\n")
            if len(stripped) > self.bound:
                self._queue.put(
                    WireError(
                        f"frame of {len(stripped)} bytes exceeds the negotiated bound "
                        f"of {self.bound}"
                    )
                )
                continue
            try:
                frame = json.loads(stripped)
            except ValueError as error:
                self._queue.put(WireError(f"frame is not one JSON object: {error}"))
                continue
            if not isinstance(frame, dict):
                self._queue.put(WireError("frame is not a JSON object"))
                continue
            self.frames.append(frame)
            self._queue.put(frame)

    def _read_stderr(self) -> None:
        assert self.process is not None and self.process.stderr is not None
        try:
            while True:
                chunk = self.process.stderr.read(4096)
                if not chunk:
                    return
                with self._stderr_lock:
                    if len(self._stderr) < 64 * 1024:
                        self._stderr.extend(chunk)
        except (ValueError, OSError):
            return

    def close(self, *, expect_exit: int | None = 0) -> int | None:
        if self.process is None:
            return None
        try:
            if self.process.poll() is None:
                try:
                    self.send_request("extension.shutdown", {})
                    self.wait_response(self._next_id, timeout=5.0)
                except (WireError, BrokenPipeError, OSError):
                    pass
                try:
                    self.process.stdin.close()
                except (BrokenPipeError, OSError):
                    pass
                try:
                    returncode = self.process.wait(timeout=5.0)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    returncode = self.process.wait(timeout=5.0)
                    self.fail("extension did not exit after shutdown; killed it")
                if expect_exit is not None and returncode != expect_exit:
                    self.fail(
                        f"extension exited {returncode}, expected {expect_exit}; "
                        f"stderr: {self.stderr_text()[:400]!r}"
                    )
                return returncode
            return self.process.poll()
        finally:
            for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
                if stream is not None:
                    try:
                        stream.close()
                    except (OSError, ValueError):
                        pass

    def fail(self, message: str) -> None:
        raise WireError(message)

    # --- writing ------------------------------------------------------------

    def send_raw(self, payload: bytes) -> None:
        assert self.process is not None and self.process.stdin is not None
        self.process.stdin.write(payload)
        self.process.stdin.flush()

    def send(self, frame: dict) -> None:
        self.send_raw(json.dumps(frame, ensure_ascii=False).encode("utf-8") + b"\n")

    def send_request(self, method: str, params: dict | None = None, request_id=None) -> int:
        if request_id is None:
            self._next_id += 1
            request_id = self._next_id
        else:
            self._next_id = max(self._next_id, request_id if isinstance(request_id, int) else 0)
        self.send(
            {
                "jsonrpc": "2.0",
                "id": request_id,
                "method": method,
                "params": params or {},
            }
        )
        return request_id

    def send_notification(self, method: str, params: dict | None = None) -> None:
        self.send({"jsonrpc": "2.0", "method": method, "params": params or {}})

    # --- reading ------------------------------------------------------------

    def next_frame(self, timeout: float | None = None) -> dict:
        if self._pending:
            return self._pending.pop(0)
        try:
            item = self._queue.get(timeout=timeout if timeout is not None else self.timeout)
        except queue.Empty:
            raise WireError(
                f"no frame within the timeout; stderr: {self.stderr_text()[:400]!r}"
            )
        if isinstance(item, WireError):
            raise item
        return item

    def wait_for(self, predicate, *, timeout: float | None = None, what: str = "frame"):
        deadline = time.monotonic() + (timeout if timeout is not None else self.timeout)
        skipped: list[dict] = []
        try:
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise WireError(
                        f"no {what} within the timeout; stderr: {self.stderr_text()[:400]!r}"
                    )
                frame = self.next_frame(timeout=remaining)
                if predicate(frame):
                    return frame
                skipped.append(frame)
        finally:
            self._pending.extend(skipped)

    def wait_response(self, request_id, timeout: float | None = None) -> dict:
        return self.wait_for(
            lambda frame: frame.get("id") == request_id and "result" in frame,
            timeout=timeout,
            what=f"response to id {request_id!r}",
        )

    def wait_error(self, request_id, timeout: float | None = None) -> dict:
        return self.wait_for(
            lambda frame: frame.get("id") == request_id and "error" in frame,
            timeout=timeout,
            what=f"error response to id {request_id!r}",
        )

    def wait_method(self, method: str, timeout: float | None = None) -> dict:
        return self.wait_for(
            lambda frame: frame.get("method") == method,
            timeout=timeout,
            what=f"{method} frame",
        )

    def request(self, method: str, params: dict | None = None) -> dict:
        request_id = self.send_request(method, params)
        return self.wait_response(request_id)

    def events_for(self, reference: str, *, timeout: float | None = None) -> list[dict]:
        """Every `agent.event` for one invocation, up to and including terminal."""
        collected: list[dict] = []
        skipped: list[dict] = []
        deadline = time.monotonic() + (timeout if timeout is not None else self.timeout)
        try:
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise WireError(
                        f"no terminal event for {reference!r}; stderr: {self.stderr_text()[:400]!r}"
                    )
                frame = self.next_frame(timeout=remaining)
                if frame.get("method") != "agent.event":
                    skipped.append(frame)
                    continue
                params = frame["params"]
                if params.get("invocationRef") != reference:
                    skipped.append(frame)
                    continue
                collected.append(params)
                if params.get("kind") == "terminal":
                    return collected
        finally:
            self._pending.extend(skipped)

    # --- convenience --------------------------------------------------------

    def initialize(self, *, major: int = 1, bound: int | None = None) -> dict:
        request_id = self.send_request(
            "extension.initialize",
            {
                "protocol": {"major": major, "minimumMinor": 0},
                "maxFrameBytes": bound if bound is not None else self.bound,
            },
        )
        ready = self.wait_method("extension.ready")
        response = self.wait_response(request_id)
        self.initialize_response = response
        self.ready = ready
        return response

    def describe(self) -> dict:
        return self.request("agent.describe")["result"]

    def execute(self, reference: str, text: str) -> dict:
        return self.request(
            "agent.execute", {"invocationRef": reference, "input": text}
        )["result"]

    def stderr_text(self) -> str:
        with self._stderr_lock:
            return bytes(self._stderr).decode("utf-8", errors="replace")


def replay(program, transcript_path: Path) -> tuple[bytes, bytes, int]:
    """Run one program with a recorded input and return its raw output.

    The replay is byte-for-byte: no frame is re-parsed and nothing is
    normalized, so a difference in ordering, spacing or encoding is a failure
    rather than a coincidence.
    """
    transcript = transcript_path.read_bytes()
    completed = subprocess.run(
        [str(argument) for argument in program],
        cwd=str(ROOT),
        input=transcript,
        capture_output=True,
        timeout=60,
        check=False,
    )
    return completed.stdout, completed.stderr, completed.returncode
