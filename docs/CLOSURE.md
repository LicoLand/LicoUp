# Change closure

Updated: 2026-09-26

Before final verification, inspect the complete changed scope:

Engineering delivery requires the complete approved implementation and its
production wiring, supported by all applicable non-live verification. A real Agent
demonstration cannot substitute for unfinished code, DSL semantics, state-machine
or scheduling tests. Report implementation gaps separately from live-only unknowns.

1. Check module ownership, dependency direction, public contracts and removal of
   replaced code/docs. Run `npm run repo:structure` and inspect its HIGH RISK findings.
   Split affected oversized files by responsibility using the
   [refactoring Skill](../crates/licoup-native/resources/licoup-refactor/SKILL.md).
   Generated files are handled at their generator. Findings outside the change
   remain recorded for their owner; do not silently expand the change.
2. Read changed documents for necessary content, current dates and a single factual
   authority. Configuration and tests own state/behavior; prose explains trade-offs.
   Match instructions to current implementation and current rules; remove obsolete
   instructions and unimplemented promises.
3. Run `npm run repo:artifacts` across the public Git candidate. Plans, blocker/progress
   reports, benchmark/test results and machine evidence stay ignored, wherever they
   were created. Keep reproducible harnesses and synthetic fixtures instead.
   Review the diff and privacy findings. Report each privacy finding with file/line,
   rule, redacted category, true/false-positive evidence, impact and remedy.
4. Run `npm run repo:impact` and inspect affected checks and adapter warnings. Verify
   both ends of changed semantic boundaries. Refresh official upstream observations
   with `npm run repo:upstream`; changed/unavailable sources need review and do not
   prove protocol breakage. Track unrelated upstream repairs in a separate Draft PR.
   Run the affected formatter and module command. Finish in-scope repairs and source
   review before running global verification. Preserve other writers' changes.
5. Once the integrated candidate is ready, run `npm run verify:closure` once. It
   refreshes registered projections, runs static global checks and regression, and
   writes a dated machine-readable report. Inspect failures and unverified entries.
   Reuse valid passing results when only a focused repair is necessary.

`npm run verify:closure -- --plan` lists the registered steps without executing them.
`npm run repo:structure -- --all` inventories the whole candidate; the default report
marks the changed scope. Source-size warnings require review, not arbitrary line
splitting. Responsibility and coupling matter even below the warning threshold.

At engineering handoff, stop at the current milestone and identify the reviewed
source, completed requirements, valid checks and remaining live-only claims. Do not
advance later milestones implicitly. The maintainer assigns centralized packaging,
installation, backed-up real-data migration, launch and live acceptance for the
integrated candidate; module implementers must not perform their own installed trials.
An explicit installation or launch assignment still does not authorize Computer Use
or user-scenario acceptance unless those actions are included in the assignment.

Live Agent conversations, paid model evaluation, gateway connections and physical
pairing are separately authorized acceptance. Run requested live targets sequentially
and record unrequested targets as not-run. Local reports stay in ignored build output.
Publication and production effects retain their own authorization boundary.

When a separately assigned live task exposes a defect, diagnose the failing stage
and its responsible owner before editing. Fix ordinary scoped defects directly.
For a structural fault, redesign or refactor the affected module and unpublished
interfaces across their producers and consumers within the approved objective.
Remove superseded paths instead of accumulating workarounds or internal versions.
Add or update focused engineering coverage, rebuild when required, then resume the
affected operation. The size of an in-scope refactor alone does not require a new
approval; a changed objective, published contract or risk boundary outside existing
authority does. Do not expand the repair into unrelated features or repeat valid
unaffected checks.

Missing real adapter validation remains a warning, including after facade or shared
transport changes. It never silently becomes a pass, and it alone does not block a
PR. Core contract/static failures do block completion. Keep one current internal
semantic contract; upstream versions and wire formats belong to adapters.
