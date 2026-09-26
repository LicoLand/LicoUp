#!/usr/bin/env python3
"""Synthetic non-compatible model provider for local verification.

This program is a real provider extension process: it speaks one line-delimited
JSON-RPC 2.0 frame per line on stdin/stdout, declares the `model-provider`
profile at the handshake, and streams its own protocol. It exists so the v7.1
provider runtime can be exercised end to end without any network, account or key
material. Everything it produces is synthetic.

The dialect `synthetic.example/native` is deliberately not a compatible one:
this package supplies its own stream adapter and its own device-code
authentication instead of imitating a compatible API.

Scenarios are selected per stream through the request input:

    {"scenario": "default"}       eight text chunks, partial usage
    {"scenario": "long"}          sixty slow chunks, for cancellation
    {"scenario": "verbatim"}      three chunks with unicode and newlines
    {"scenario": "unknown-usage"} usage that reports nothing but the currency
    {"scenario": "fail"}          a stream that ends failed

Flags (local verification only):
    --no-cancel   declare no modelProvider.cancel method
    --no-auth     declare no auth.* methods
"""

import json
import sys
import threading
import time

PROTOCOL_MAJOR = 1
MAX_FRAME_BYTES = 64 * 1024

STREAM_CHUNKS = {
    "default": 8,
    "long": 60,
    "verbatim": 3,
    "unknown-usage": 4,
    "fail": 3,
}
STREAM_DELAY_SECONDS = {
    "default": 0.01,
    "long": 0.05,
    "verbatim": 0.005,
    "unknown-usage": 0.005,
    "fail": 0.005,
}

VERBATIM_TEXTS = [
    "line one\n",
    "line two with ünïcode ✓ and a tab\there\n",
    "末尾 done",
]

MODELS = [
    {
        "id": "synthetic-text",
        "displayName": "Synthetic Text",
        "inputModalities": ["text"],
        "outputModalities": ["text"],
        "tools": None,
        "reasoning": None,
        "contextTokens": None,
        "pricingSource": None,
    },
    {
        "id": "synthetic-tools",
        "displayName": "Synthetic Tools",
        "inputModalities": ["text", "image"],
        "outputModalities": ["text"],
        "tools": True,
        "reasoning": False,
        "contextTokens": 32768,
        "pricingSource": "synthetic.example/list-price",
    },
]


class Provider:
    def __init__(self, advertise_cancel, advertise_auth):
        self.advertise_cancel = advertise_cancel
        self.advertise_auth = advertise_auth
        self.write_lock = threading.Lock()
        self.streams = {}
        self.finished = {}
        self.flows = {}
        self.revoked = set()
        self.next_flow = 0
        self.stopped = False

    # -- frames -----------------------------------------------------------

    def send(self, frame):
        line = json.dumps(frame, ensure_ascii=False, separators=(",", ":"))
        with self.write_lock:
            sys.stdout.write(line + "\n")
            sys.stdout.flush()

    def result(self, frame_id, result):
        self.send({"jsonrpc": "2.0", "id": frame_id, "result": result})

    def error(self, frame_id, code, message):
        self.send({"jsonrpc": "2.0", "id": frame_id, "error": {"code": code, "message": message}})

    def notify(self, method, params):
        self.send({"jsonrpc": "2.0", "method": method, "params": params})

    def declared_methods(self):
        methods = [
            "extension.initialize",
            "extension.ready",
            "extension.shutdown",
            "modelProvider.describe",
            "modelProvider.stream",
            "modelProvider.models",
            "modelProvider.reconcile",
        ]
        if self.advertise_cancel:
            methods.append("modelProvider.cancel")
        if self.advertise_auth:
            methods.extend(["auth.begin", "auth.continue", "auth.refresh", "auth.revoke"])
        return methods

    # -- dispatch ---------------------------------------------------------

    def run(self):
        for line in sys.stdin:
            line = line.strip()
            if not line:
                continue
            try:
                frame = json.loads(line)
            except ValueError:
                continue
            self.dispatch(frame)
            if self.stopped:
                break

    def dispatch(self, frame):
        method = frame.get("method")
        frame_id = frame.get("id")
        params = frame.get("params") or {}
        if method == "extension.initialize":
            self.handle_initialize(frame_id, params)
        elif method == "extension.shutdown":
            self.result(frame_id, {})
            self.stopped = True
        elif method == "modelProvider.describe":
            self.handle_describe(frame_id)
        elif method == "modelProvider.models":
            self.result(frame_id, {"models": MODELS})
        elif method == "modelProvider.reconcile":
            self.handle_reconcile(frame_id, params)
        elif method == "modelProvider.stream":
            self.handle_stream(frame_id, params)
        elif method == "modelProvider.cancel":
            self.handle_cancel(frame_id, params)
        elif method == "auth.begin":
            self.handle_auth_begin(frame_id, params)
        elif method == "auth.continue":
            self.handle_auth_continue(frame_id, params)
        elif method == "auth.refresh":
            self.handle_auth_refresh(frame_id, params)
        elif method == "auth.revoke":
            self.handle_auth_revoke(frame_id, params)
        else:
            self.error(frame_id, -32601, "method not declared: %s" % method)

    def handle_initialize(self, frame_id, params):
        self.result(
            frame_id,
            {
                "protocol": {"major": PROTOCOL_MAJOR, "minimumMinor": 0},
                "maxFrameBytes": MAX_FRAME_BYTES,
                "acceptedProfiles": ["model-provider"],
            },
        )
        capabilities = ["synthetic.example/native-stream"]
        if self.advertise_auth:
            capabilities.append("synthetic.example/device-code-auth")
        self.notify(
            "extension.ready",
            {
                "protocol": {"major": PROTOCOL_MAJOR, "minimumMinor": 0},
                "methods": self.declared_methods(),
                "profiles": [
                    {"id": "model-provider", "major": PROTOCOL_MAJOR, "capabilities": capabilities}
                ],
            },
        )

    def handle_describe(self, frame_id):
        self.result(
            frame_id,
            {
                "provider": {
                    "id": "synthetic.example",
                    "displayName": "Synthetic Custom Provider",
                    "dialects": ["synthetic.example/native"],
                    "catalog": "discovered",
                    "auth": ["device-code"] if self.advertise_auth else [],
                }
            },
        )

    # -- streams ----------------------------------------------------------

    def handle_reconcile(self, frame_id, params):
        invocation_ref = params.get("invocationRef")
        record = self.finished.get(invocation_ref)
        if record is None:
            # This process never ran the invocation; the host reconciles against
            # its own durable record instead of reading a missing answer as
            # success.
            self.result(frame_id, {"invocationRef": invocation_ref, "state": "unknown"})
            return
        result = {"invocationRef": invocation_ref}
        result.update(record)
        self.result(frame_id, result)

    def handle_stream(self, frame_id, params):
        invocation_ref = params.get("invocationRef")
        if not invocation_ref:
            self.error(frame_id, -32602, "invocationRef is required")
            return
        scenario = (params.get("input") or {}).get("scenario", "default")
        cancel = "supported" if self.advertise_cancel else "unsupported"
        self.streams[invocation_ref] = {"cancelled": False}
        self.result(
            frame_id,
            {"invocationRef": invocation_ref, "started": True, "cancel": cancel},
        )
        threading.Thread(
            target=self.run_stream,
            args=(invocation_ref, scenario, params),
            daemon=True,
        ).start()

    def handle_cancel(self, frame_id, params):
        if not self.advertise_cancel:
            self.error(frame_id, -32601, "modelProvider.cancel is not declared")
            return
        invocation_ref = params.get("invocationRef")
        stream = self.streams.get(invocation_ref)
        if stream is None:
            self.result(frame_id, {"invocationRef": invocation_ref, "outcome": "unknown"})
            return
        stream["cancelled"] = True
        self.result(frame_id, {"invocationRef": invocation_ref, "outcome": "acknowledged"})

    def run_stream(self, invocation_ref, scenario, params):
        chunks = STREAM_CHUNKS.get(scenario, STREAM_CHUNKS["default"])
        delay = STREAM_DELAY_SECONDS.get(scenario, STREAM_DELAY_SECONDS["default"])
        sequence = 0

        def emit(fields):
            nonlocal sequence
            sequence += 1
            body = {"invocationRef": invocation_ref, "sequence": sequence}
            body.update(fields)
            self.notify("modelProvider.stream", body)

        credential = params.get("credentialRef") or "none"
        credential_state = params.get("credentialState") or "unknown"
        principal = params.get("principal") or "none"
        effect = params.get("effectRef") or "none"
        emit(
            {
                "kind": "notice",
                "body": "credential=%s;state=%s;principal=%s;effect=%s"
                % (credential, credential_state, principal, effect),
            }
        )

        for index in range(chunks):
            if self.streams.get(invocation_ref, {}).get("cancelled"):
                break
            time.sleep(delay)
            if scenario == "verbatim":
                text = VERBATIM_TEXTS[index % len(VERBATIM_TEXTS)]
            else:
                text = "chunk %d " % (index + 1)
            emit({"kind": "text", "body": text})

        if self.streams.get(invocation_ref, {}).get("cancelled"):
            emit({"kind": "terminal", "outcome": "cancelled", "usage": {}})
            self.finished[invocation_ref] = {"state": "cancelled", "usage": {}}
        elif scenario == "fail":
            emit(
                {
                    "kind": "terminal",
                    "outcome": "failed",
                    "error": {
                        "code": "synthetic.example/stream-failure",
                        "message": "synthetic provider ended the stream as failed",
                    },
                    "usage": {"inputTokens": 5},
                }
            )
            self.finished[invocation_ref] = {
                "state": "failed",
                "usage": {"inputTokens": 5},
            }
        else:
            if scenario != "unknown-usage":
                emit(
                    {
                        "kind": "usage",
                        "usage": {
                            "inputTokens": 12,
                            "outputTokens": None,
                            "cost": {"amount": None, "currency": "USD", "quality": "unknown"},
                        },
                    }
                )
            emit(
                {
                    "kind": "terminal",
                    "outcome": "completed",
                    "usage": {"inputTokens": 12, "outputTokens": None},
                }
            )
            self.finished[invocation_ref] = {
                "state": "completed",
                "usage": {"inputTokens": 12, "outputTokens": None},
            }
        self.streams.pop(invocation_ref, None)

    # -- authentication ---------------------------------------------------

    def handle_auth_begin(self, frame_id, params):
        if not self.advertise_auth:
            self.error(frame_id, -32601, "auth.begin is not declared")
            return
        self.next_flow += 1
        flow_id = "flow-%d" % self.next_flow
        self.flows[flow_id] = {"polls": 0}
        if params.get("method") == "secret":
            challenge = {"kind": "secret-input", "label": "Synthetic provider key"}
        else:
            challenge = {
                "kind": "device-code",
                "verificationUri": "https://auth.example.invalid/device",
                "userCode": "SYNTH-0001",
                "expiresInSeconds": 600,
            }
        self.result(
            frame_id,
            {"flowId": flow_id, "stage": "awaiting-user", "challenge": challenge},
        )

    def handle_auth_continue(self, frame_id, params):
        if not self.advertise_auth:
            self.error(frame_id, -32601, "auth.continue is not declared")
            return
        flow_id = params.get("flowId")
        flow = self.flows.get(flow_id)
        if flow is None:
            self.error(frame_id, -32602, "unknown flow")
            return
        kind = (params.get("input") or {}).get("kind", "user-confirmed")
        if kind == "secret-input":
            self.result(
                frame_id,
                {
                    "flowId": flow_id,
                    "stage": "authorized",
                    "credentialRef": "credential:synthetic-secret",
                },
            )
            return
        flow["polls"] += 1
        if flow["polls"] < 2:
            self.result(frame_id, {"flowId": flow_id, "stage": "pending"})
            return
        self.result(
            frame_id,
            {
                "flowId": flow_id,
                "stage": "authorized",
                "credentialRef": "credential:synthetic-device",
            },
        )

    def handle_auth_refresh(self, frame_id, params):
        if not self.advertise_auth:
            self.error(frame_id, -32601, "auth.refresh is not declared")
            return
        reference = params.get("credentialRef")
        self.result(
            frame_id,
            {"stage": "authorized", "credentialRef": reference or "credential:synthetic-device"},
        )

    def handle_auth_revoke(self, frame_id, params):
        if not self.advertise_auth:
            self.error(frame_id, -32601, "auth.revoke is not declared")
            return
        reference = params.get("credentialRef")
        if reference:
            self.revoked.add(reference)
        self.result(frame_id, {"revoked": bool(reference)})


def main(argv):
    advertise_cancel = "--no-cancel" not in argv
    advertise_auth = "--no-auth" not in argv
    Provider(advertise_cancel, advertise_auth).run()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
