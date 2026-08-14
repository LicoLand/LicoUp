"""Bounded JSON helpers used by LicoUp's built-in basic strategy.

The runtime supplies one canonical JSON document on stdin. The helper never
opens the network, discovers executables, or reads outside its package.
"""

from __future__ import annotations

import json
import sys
from typing import Any

MAX_INPUT_BYTES = 1024 * 1024


def read_input() -> dict[str, Any]:
    raw = sys.stdin.buffer.read(MAX_INPUT_BYTES + 1)
    if len(raw) > MAX_INPUT_BYTES:
        raise ValueError("strategy_input_too_large")
    value = json.loads(raw.decode("utf-8"))
    if not isinstance(value, dict):
        raise ValueError("strategy_input_invalid")
    return value


def write_output(value: dict[str, Any]) -> None:
    sys.stdout.write(json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")))
