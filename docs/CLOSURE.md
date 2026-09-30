# Change closure

Updated: 2026-10-01

Before final verification, inspect the complete changed scope:

Engineering delivery requires the complete approved implementation and its
production wiring, supported by all applicable non-live verification. A real Agent
demonstration cannot substitute for unfinished code, DSL semantics, state-machine
or scheduling tests. Report implementation gaps separately from live-only unknowns.

1. Check module ownership, dependency direction, public contracts and removal of
   replaced code/docs. Select the registered suites for the changed paths with
   `npm run client:regression:list` and
   `npm run client:regression -- --changed-from <ref> --dry-run`. Catalog selection
   maps paths to registered checks; it is not a complete impact graph, so review the
   affected owners and both sides of each changed boundary manually and report an
   unmapped path as an ownership gap. Resolve findings in the changed scope and
   split oversized files by responsibility under normal source review. Findings
   outside the change remain recorded for their owner; do not silently expand the
   change.
2. Read changed documents for necessary content, current dates and a single factual
   authority. Configuration and tests own state/behavior; prose explains trade-offs.
   Match instructions to current implementation and current rules; remove obsolete
   instructions and unimplemented promises.
3. Review the whole public Git candidate for sensitive content and misplaced local
   material. `npm run repo:local-info-hygiene` scans the public candidate with the
   canonical `lico-dev` privacy scanner and blocks when that tooling is unavailable;
   `npm run repo:local-info-hygiene:self-test` validates the helper with synthetic
   fixtures, and `npm run repo:workspace-cache-boundary` checks dependency-directory
   boundaries. Plans, blocker/progress reports, benchmark and test results and
   machine evidence stay ignored wherever they were created; keep reproducible
   harnesses and synthetic fixtures instead. Review the diff and privacy findings.
   Report each privacy finding with file/line, rule, redacted category,
   true/false-positive evidence, impact and remedy.
4. Run the affected formatters after all writers finish: `npm run client:format`,
   or the `client:format:flutter` / `client:format:rust` entry for the affected
   sources. Then run the owning module command and the affected consumer checks.
   After focused checks pass, run `npm run client:gate:source` once and only the
   affected `client:gate:flutter`, `client:gate:rust`, `client:gate:android` or
   `client:gate:dependencies` lane. Finish in-scope repairs and source review
   before global verification. Preserve other writers' changes.
5. Once the integrated candidate is ready, run the selected complete regression once
   and inspect failures and unverified entries. Reuse valid passing results when only
   a focused repair is necessary. The run records its report privately at
   `build/reports/client-module-regression.json`; it does not publish or install.

At engineering handoff, stop at the current milestone and identify the reviewed
source, completed requirements, valid checks and remaining live-only claims. An
explicit finite programme assignment may authorize advancing to the next
dependency-satisfied milestone after the current milestone is reviewed and its
delivery is recorded; without one, do not advance later milestones implicitly.
The maintainer assigns centralized packaging, installation, backed-up real-data
migration, launch and live acceptance for the integrated candidate; module
implementers must not perform their own installed trials. An explicit installation
or launch assignment still does not authorize Computer Use or user-scenario
acceptance unless those actions are included in the assignment.

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
