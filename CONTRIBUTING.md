# Contributing

Updated: 2026-09-25

[简体中文](CONTRIBUTING.zh-CN.md)

## Account and authorship

Contribute through a GitHub account you control and take responsibility for the
changes. A manually registered account dedicated to Agent work is acceptable;
its name need not resemble a person's legal name. Account authentication establishes
accountability, not verified real-world identity. Vendor/service Agent identities
must not replace the responsible contributor.

Before the first commit, authenticate with `gh auth login`, then run
`npm run repo:identity:install` and `npm run repo:identity:verify`. Repeat when
switching accounts. New commits use the authenticated account's GitHub identity;
preserve historical authors. Review Agent-produced changes yourself and disable
automatic attribution trailers. Do not bypass repository hooks.

## Branch, commit and pull request

Start a scoped `feature/`, `fix/`, `docs/`, `refactor/`, `test/`, or `chore/` branch.
Describe the concrete change in the commit. Open a **Draft PR** to `nightly` as soon
as the initial reviewable commit is pushed, then push the remaining module commits
to that Draft. Include at least one attributable commit per affected module; later
correction commits are welcome. Mark it ready only after the complete feature and
its dependent consumers are integrated. A one-sided protocol change or a half
migration is not mergeable. The core client must remain a functioning whole.

The PR includes:

- the problem and resulting behavior, and the related Issue if one exists;
- the checks run and their outcomes, explicitly identifying unverified behavior;
- any public contract or migration impact.

Use synthetic or redacted reproductions. Never submit credentials, personal data,
local paths or raw runtime output. Development plans, progress/blocker reports,
benchmark results, test reports and screenshots belong in ignored local directories.
They describe one environment and are not durable project facts. Contribute reusable
harnesses, synthetic fixtures and commands instead. Review the whole Git candidate
with `npm run repo:artifacts`, including files outside the usual report directories. Before submitting, finish the developer closure
checks. Code review and a passing check do not establish live acceptance. Missing real
Agent validation is a visible warning, not a merge blocker by itself. Name affected
adapters and what remains unverified; never label them verified from static checks.
Shared semantic/transport changes require checking every registered consumer.
Upstream protocol drift discovered during closure belongs in a separate scoped PR.

## Issues

Describe the user-visible problem, a minimal redacted reproduction and the desired
behavior. For feature requests, explain the concrete use case and affected module.
Small independently reviewable changes that respect module boundaries are easier to
assess; private logs, personal plans and unrelated cleanups do not belong in an Issue.

Merge by merge commit. After confirming that the merged commit is on `nightly`,
delete only that contribution's temporary local and remote branches. Retain unmerged
work and other contributors' branches. Protected promotion and publication require
separate maintainer authority; do not replace published artifacts.

The maintained README-only fast path follows the same identity, privacy and pull
request rules. Its file membership is defined by repository configuration; do not
use it to bypass checks for code changes.

LicoUp uses `AGPL-3.0-or-later`.
