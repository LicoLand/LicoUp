---
name: lico-mail-import-ops
description: Use when operating, debugging, or documenting LicoLite macOS Mail import, authorization, diagnostics, local mail knowledge index, evidence opening, and cloud taxonomy cache behavior.
---

# LicoLite Mail Import Ops

## Purpose

Provide a runbook for the Flutter client's macOS Mail import and local mail knowledge workspace.

## Workflow

1. Read `references/mail-import-map.md`.
2. Check client log and diagnostics before changing code.
3. Verify macOS Mail authorization state.
4. Refresh index stats and knowledge graph before judging import quality.
5. Use evidence opening to validate message ids.

When raw mail needs to become a DOCX or Markdown artifact, use `$email-to-kb-doc`.
