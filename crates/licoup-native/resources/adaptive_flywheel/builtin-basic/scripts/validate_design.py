"""Validate the bounded regression handoff for the built-in basic strategy."""

from __future__ import annotations

from graph_helpers import read_input, write_output


def main() -> None:
    value = read_input()
    revision = value.get("sourceRevision")
    prior = value.get("lastRegressionRevision")
    if not isinstance(revision, str) or not revision:
        raise ValueError("source_revision_missing")
    write_output({"revision": revision, "skipped": revision == prior, "success": True})


if __name__ == "__main__":
    main()
