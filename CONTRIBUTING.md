# Contributing

English · [简体中文](CONTRIBUTING.zh-CN.md) · [Home](README.md)

Thank you for helping LicoUp. Keep each change small enough to review and
test as one clear client feature, module, or flow.

## Set up

You need Node.js 22 or 24 for the source policy. Install Flutter, Rust, Java,
and Android tooling only when the affected technology lane requires them.

```bash
npm ci
```

During development, run the smallest relevant checks. Before handoff, run the
targeted tests for the changed module. After every intended change is confirmed
effective, run the mandatory Node-only source policy once and only the affected
technology lanes. The lanes are independent and may run in parallel. The commit
gate never builds or publishes every platform.

```bash
npm run client:gate:source
npm run client:gate:flutter         # Flutter changes only
npm run client:gate:rust            # Rust changes only
npm run client:gate:android         # Android changes only
npm run client:gate:dependencies    # dependency authority changes only
npm run client:gate:release-policy  # release policy changes only
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

When every locked dependency is already cached, the dependency audit has a
separate offline form: `npm run client:deps:audit:offline`. It does not cause
unaffected language or platform lanes to run.

## Commit identity and authorship

Every commit must carry exactly one developer identity. Its Git `Author` name,
email, and immutable GitHub account must match the account currently
authenticated by GitHub CLI. The immutable GitHub `Committer` account must be
that same developer; GitHub may rewrite the raw committer name or email while
performing a server-side merge. Locally created commits still require matching
Author and Committer name and email. After cloning the repository, and whenever
`gh auth` changes to a different account, install the repository policy:

```bash
npm run repo:identity:install
npm run repo:identity:verify
```

The installer uses the account's canonical GitHub noreply address and enables
the repository-controlled `pre-commit`, `commit-msg`, and `pre-push` hooks.
The hooks inspect every outgoing commit, not only `HEAD`. Missing, redirected,
modified, symbolic-link, or non-executable policy files fail closed. Never use
`--no-verify`, change `core.hooksPath`, or otherwise bypass these gates.

An Agent may assist a developer, but it must never replace, overwrite, or claim
the developer's authorship. An Agent's name, email, or other contact details
must not appear as an Author, Committer, co-author, sign-off, attribution
trailer, or identity-shaped line. This includes Claude Code, Cursor, Codex,
Copilot, and every other Agent or bot. Claiming human work under an Agent's
contact details is false identity information and a provenance violation; the
local hooks and remote Rulesets reject it. The developer must review and accept
the change personally before committing it.

Every change starts on a temporary upstream branch. Name an ordinary branch
with an action prefix that explains its purpose: `feature/<topic>`,
`fix/<topic>`, `docs/<topic>`, `refactor/<topic>`, `test/<topic>`, or
`chore/<topic>`. Release candidates use
`release-candidate/v<version>-<target>`. The all-branch metadata Ruleset applies
while any temporary branch is created, so its first commit cannot evade
identity enforcement. Merge a temporary branch only into `nightly` through a
pull request that creates a merge commit. Do not rebase or squash it into
`nightly`, and never write a change directly to a long-lived branch.

## Release preflight

Release preparation is defined by `tools/client-release-template.json`. Do not
reconstruct runner commands by trial and error. Run one bounded command for
each stage:

```bash
npm run client:release -- push nightly --version 0.1.1 --target macos-arm64
npm run client:release -- push stable --version 0.1.1 --target macos-arm64
npm run client:release -- push release --version 0.1.1 --target macos-arm64
npm run client:release -- publish --version 0.1.1 --target macos-arm64
```

The first command creates `release-candidate/v<version>-<target>` before changing any
file. On that temporary branch it records one release target, changes the version
once, runs only the common and selected-platform gates required by the pull request, and creates exactly one release
commit. Only after the temporary branch passes every declared required
LicoUp pull-request check does it create a merge commit in `nightly`; release
candidates are never rebased or squashed into `nightly`. The next two commands independently
promote the same target through `nightly -> stable` and `stable -> release`; a
target mismatch fails closed. The last command makes the selected remote builder
build the client, then signs, archives, checksums, and publishes that successful
build while monitoring to a terminal result without an operator-side timeout.
Functional, UI, dependency, and local-agent validation belongs to the local
candidate gate and is not repeated on the release machine.
Remote publication validity is selected by
`tools/client-remote-release-strategies.json`. Its sole active strategy is
`build-success`: a selected-platform build that exits successfully is valid for
publication; the remote builder must not repeat the local validation gates.
For macOS, that same `publish` action also downloads the workflow's update
artifact, signs `LicoUp-update-stable.json` with the locally held update keys,
verifies the remote update asset set, and only then makes the Release public.
Each command is independently resumable. Active Rulesets must not be disabled,
bypassed, or changed during any stage.

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

## Native interface consistency

The Flutter client and the Rust native core share two interfaces:

- Generated contract types, owned by `schemas/client_bridge/` and generated
  into Dart (`apps/desktop/lib/src/contracts/generated/*.g.dart`) and Rust
  (`crates/licoup-native/src/ffi/generated/*.rs`) from one schema.
- The native CLI command surface (`licoup.stdio.v1` frames and one-shot
  arguments). The Rust side admits options through `admitted_params` in
  `crates/licoup-native/src/ffi/commands/`; the Flutter side sends them from
  `apps/desktop/lib/src/platform/native_client/`.

The packaged app carries its own sidecar, so a running app keeps the old
native binary until it is rebuilt. Rebuild and verify the client bundle
after any native interface change.

## Documentation rules

- Use short sentences and common words.
- Keep English as the normative public entry and link each maintained
  Simplified Chinese localization back to it. Shared product facts in the two
  root READMEs change together.
- Use a small Mermaid diagram when a data flow is hard to explain in text.
- Keep product text focused on diversity, connection, openness, integration,
  and user control.
- Treat `README.md` as the public product page. Check every claim.
- Keep structured plans under `docs/plans/`. Keep audit reports, temporary
  proposals, and other one-off documents under `docs/reports/`. Both paths are
  local only.
- Do not add local skills or temporary scripts to the repository.

## Pull request checklist

- The change has one clear scope.
- Native CLI or generated contract changes keep the Flutter and Rust sides
  consistent in the same change.
- Old paths and old names are removed when a migration is complete.
- New or changed tests use made-up, redacted data.
- Public documentation has matching English and Chinese text.
- No sensitive values or raw runtime output are included.
- Commit Author and Committer match the current `gh` account, with no second
  signature, attribution trailer, Agent identity, or bypassed hook.

LicoUp uses the `AGPL-3.0-or-later` license.
