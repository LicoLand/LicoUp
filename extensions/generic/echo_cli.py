#!/usr/bin/env python3
"""A command-line program that existed before LicoUp was configured for it.

The generic carrier wraps this without modifying it: it reads standard input,
writes one `echo: <line>` line per input line, and exits zero. `--slow` spaces
the lines out so a cancellation has work to interrupt; `--bulk N` prints N
lines without reading input, which lets a caller exercise bounded framing.
"""
from __future__ import annotations

import argparse
import sys
import time


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description="Echo standard input line by line.")
    parser.add_argument("--slow", action="store_true", help="pause between lines")
    parser.add_argument("--bulk", type=int, default=0, help="print N lines and exit")
    arguments = parser.parse_args(argv)
    if arguments.bulk:
        for index in range(arguments.bulk):
            sys.stdout.write(f"bulk line {index}\n")
            sys.stdout.flush()
            if arguments.slow:
                time.sleep(0.005)
        return 0
    for line in sys.stdin:
        sys.stdout.write(f"echo: {line}")
        sys.stdout.flush()
        if arguments.slow:
            time.sleep(0.02)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
