# Lico Arc CLI Workflow Examples

[Documentation](../README.md) · [Runbook](../RUNBOOK.md)

These examples project the implemented native CLI surface. The command dispatch
and contract tests under `crates/lico-client-native/src/bin/` are authoritative.
All values below are placeholders; do not substitute real credentials, private
addresses, device identifiers, or runtime payloads in committed examples.

## Discover local agents

```bash
lico-client targets scan
```

The result stays in the client-owned local target cache.

## Read local conversation history

```bash
lico-client conversations list --agent <agent-id>
```

This is a read-only history projection. The semantic response contract is
defined by
[`packages/contracts/client/semantic-conversation.schema.json`](../../packages/contracts/client/semantic-conversation.schema.json).

## Preview a skill installation

```bash
lico-client skill list --agent <agent-id>
lico-client skill get <skill-id> --agent <agent-id> --json
lico-client skill install plan --agent <agent-id> --url <public-skill-url>
```

Review the selected target, destination, package digest, and affected files
before applying any local write. Preview never executes skill code.

## Preview a local conversation backup

```bash
lico-client snapshots archive jobs preview \
  --selection-mode exact-keyword \
  --query <exact-keyword> \
  --path <destination-dir>
```

Apply only the exact returned preview binding:

```bash
lico-client snapshots archive jobs create \
  --selection-mode exact-keyword \
  --query <exact-keyword> \
  --path <destination-dir> \
  --plan-binding <preview-binding>
```

The destination remains local. A changed source, selection, destination, or
conflict state invalidates the preview.

## Read local usage aggregates

```bash
lico-client agent-usage scan --agent <agent-id> --history-days 30
lico-client agent-usage report --agent <agent-id> --limit 10
```

Reports contain aggregates and attribution quality, not prompts, replies,
accounts, native identifiers, or local paths.
