---
name: licoup-refactor
description: Decompose an oversized source file by responsibility while preserving behavior. Load only when the user or a project closure review explicitly selects this Skill.
---

# Refactor a large module

Updated: 2026-09-25

This optional public Skill works in any codebase. Do not load it by default.
Use the project's own module boundaries and verification commands.

1. Read the changed file, its callers and owning tests. Identify separate reasons
   for change: domain decisions, persistence, transport, presentation or scheduling.
   Size is a signal; generated output should be corrected at its generator.
2. Establish the affected behavior with the smallest meaningful existing tests.
   Preserve public signatures and observable behavior. Add a focused behavioral
   test only where the extraction exposes an uncovered risk.
3. Extract pure data and low-dependency operations first. Use
   [Extract Class](https://refactoring.com/catalog/extractClass.html) for independent
   responsibilities and [Split Phase](https://refactoring.com/catalog/splitPhase.html)
   when one operation combines stages with different inputs or effects. Keep
   interfaces with their consumer and dependencies flowing in one direction.
4. Move each responsibility with its owning tests. Keep a small facade only where
   it is the intended public interface. Do not create arbitrary numbered fragments,
   forwarding layers with no purpose, or global utilities for one caller.
5. Run affected tests after meaningful moves, review the full diff and remove the
   superseded implementation. Use a one-time search for retired paths/references;
   do not retain migration-only assertions as permanent tests. Finish through the
   project's closure process once all changes and scoped repairs are complete.

Do not absorb unrelated refactoring or modify public behavior to make an extraction
easier. Explain any required contract change before taking that dependent action.
