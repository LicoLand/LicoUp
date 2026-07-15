# Local Agent Runtime and Orchestration Validation

## Requirement matrix

| Requirements | Required evidence |
| --- | --- |
| REQ-001, REQ-006, REQ-007, REQ-015 | Canonical manifest schema, generated-projection consistency, exact-set mutation tests, synthetic adapter contribution, dynamic reload/rollback/drain tests, and retired-authority scans |
| REQ-002, REQ-003, REQ-004, REQ-005 | Per-adapter official-lane contract tests, fake-child negative tests, live native↔Arc exact continuation, ordered pre-terminal streaming, timeout/cancel/cleanup, and bounded supervisor tests |
| REQ-008, REQ-012 | Pure planner tests, deterministic tie-breaks, DAG topology, semaphore limits, cancellation, circuit/allowance/readiness changes, known/unknown failure disposition, and route explanation |
| REQ-009, REQ-010, REQ-011 | Private-file/no-follow tests, typed path/digest acknowledgement, target budget boundaries, unknown-limit behavior, framework compression, hierarchical overflow, fidelity failure, bounded cache, and cleanup |
| REQ-013 | Secret-key rejection, argv/process inspection, path/native-ID redaction, approval deny-by-default, bounded evidence, and privacy scan |
| REQ-014, REQ-016 | GUI/CLI/direct/routed same-lane tests, real reply persistence, next-turn context, Release-product UI live checks, aggregate client verification, rebuild, and launch |

## Mandatory negative checks

- Missing, duplicate, extra, or mismatched manifest/driver/package/render/readiness identities fail.
- Prompt, native ID, context path, credential, or private data in argv or public output fail.
- Empty, changed, latest, ambiguous, or cross-adapter resume identity fails without opening a new session.
- Chunk after terminal, duplicate terminal, non-monotonic sequence, cross-turn event, or unowned cancellation fails.
- Unknown context limit, underestimated reserved budget, missing required section, digest mismatch, unacknowledged path, compression fidelity failure, or cleanup escape fails closed.
- Invalid configuration never replaces last-good state; a revision cannot change an active turn; disable/remove cannot leak a watcher, process, session, cache entry, or artifact.
- Unknown-outcome dispatch cannot fall back or retry automatically.
- Fixture, debug-only integration, or sidecar-only success cannot set product readiness.

## Per-adapter live acceptance

For every canonical adapter, use an authorized local framework installation and one acceptance client artifact to prove:

1. Arc creates a native session, receives a real ID and at least one progressive event before terminal, and native history reads the result.
2. Arc sends a second and third turn using the same ID; the framework reports the same identity and ordered history.
3. A native-created session is resumed by Arc and an Arc-created session is resumed by the native framework where the official interface supports bidirectional access.
4. Effective model, reasoning, working-directory, permission, error, timeout, cancel, cleanup, and usage semantics match the manifest.
5. Evidence binds source, artifact, sidecar, manifest, registry revision, framework capability probe, and continuity digests while storing no raw conversation or path.

The aggregate reducer enables sending only when every canonical adapter has current evidence. A manifest, driver, registry, or artifact change invalidates the affected evidence.

## Context and orchestration end-to-end

- Route a fitting conversation and prove one private artifact path/digest is acknowledged by the selected native framework and cleaned after terminal.
- Route an oversize conversation, prove budget overflow before dispatch, invoke the policy-selected ready compressor through its official lane, preserve all required sections, and hand off the compressed artifact by path.
- Repeat the same digest and budget to prove cache reuse; change model, budget, compressor, policy, or registry revision to prove invalidation.
- Exercise every strategy with real replies: serial order, safe priority fallback, bounded parallel execution, coordinator-worker synthesis, cancellation, circuit change, and policy reload at a message boundary.
- Prove every final reply enters the same Lico thread and influences the next routing decision without copying unbounded raw worker histories.

## Delivery closure

Each Node runs its mapped focused tests and is committed locally before `complete --delivered`. Final validation runs manifest validation and label checks, canonical client verification selected by `lico-dev workflow plan client`, privacy checks, native and Flutter unit/integration suites, live adapter and routing acceptance where authorized, then rebuilds and opens the client. Android code changes require an independent verification subagent to build and, when an authorized device is connected, install and launch the fresh client.
