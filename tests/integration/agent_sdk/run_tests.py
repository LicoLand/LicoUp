#!/usr/bin/env python3
"""Run the v7.1 Agent SDK component suite.

    python3 -B tests/integration/agent_sdk/run_tests.py

Every case starts real local processes: the SDK samples, the generic carrier
with a wrapped command, and the compiled native sample. No model, no network and
no external service is involved.
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path


def main() -> int:
    suite = unittest.defaultTestLoader.discover(
        str(Path(__file__).resolve().parent), pattern="test_*.py"
    )
    result = unittest.TextTestRunner(verbosity=2).run(suite)
    return 0 if result.wasSuccessful() else 1


if __name__ == "__main__":
    raise SystemExit(main())
