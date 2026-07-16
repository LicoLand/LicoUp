# Contributing

English · [简体中文](CONTRIBUTING.zh-CN.md) · [Home](README.md)

Thank you for helping Lico Arc. Keep each change small enough to review and
test as one clear client feature, module, or flow.

## Set up

You need Node.js 22 or 24, Flutter stable, and Rust stable.

```bash
npm ci
npm run client:get
```

During development, run the smallest relevant checks. Before handoff, run the
targeted tests for the changed module. Run the full client verification once,
and only after every intended change has been confirmed effective. Never repeat
the full regression during implementation; it expands the feedback loop and
contends with other agents working in parallel.

```bash
npm run client:analyze
npm run client:test
npm run client:native:test
```

Build-producing tests share one managed compiler target. The test runner holds
an active lease while a build is using it and marks the output reclaimable on
every terminal path. Inspect or remove only inactive, marked output with:

```bash
npm run client:artifacts:status
npm run client:artifacts:prune -- --dry-run
npm run client:artifacts:prune
```

Pruning never removes Cargo, Pub, Gradle, SDK, or toolchain download caches, so
the next build can continue to reuse downloaded dependencies. Unmanaged legacy
targets are reported but are not deleted automatically. After an abnormal test
exit, a structurally valid dead lease remains protected for a grace period and
only then becomes reclaimable; malformed or tampered records always fail closed.

When every locked dependency is already cached, run the one final verification
without network access using `LICO_CLIENT_VERIFY_OFFLINE=1 npm run client:verify`.

## Privacy rules

- Never commit secrets, local paths, user content, account data, device details,
  logs, or raw runtime reports.
- Use synthetic, redacted test data. Test frameworks may be public; real user
  and system data may not.
- Keep sensitive data on the client. Peer content must be encrypted before it
  leaves the sender.
- Do not add a general path that sends user content or runtime data to a
  service.
- Any allowed external transfer must require a fresh direct user approval bound
  to the exact destination, purpose, scope, and content digest.

## Documentation rules

- Use short sentences and common words.
- Keep an English file and a matching Simplified Chinese file. English is the
  default entry.
- Use a small Mermaid diagram when a data flow is hard to explain in text.
- Keep product text focused on diversity, connection, openness, integration,
  and user control.
- Treat `README.md` as the public product page. Check every claim.
- Keep plans under `docs/plan/` and one-off work under `.local/`. Both paths are
  local only.
- Do not add local skills or temporary scripts to the repository.

## Pull request checklist

- The change has one clear scope.
- Old paths and old names are removed when a migration is complete.
- New or changed tests use made-up, redacted data.
- Public documentation has matching English and Chinese text.
- No sensitive values or raw runtime output are included.

Lico Arc uses the `GPL-3.0-or-later` license.
