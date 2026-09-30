# Adaptive Flywheel Strategies

Updated: 2026-09-25

[简体中文](ADAPTIVE-FLYWHEEL.zh-CN.md) · [Functionality](README.md)

Adaptive Flywheel imports user-authored JSON Graphs and binds their actor slots to
ordered Agent candidates. The Graph defines topology; its name does not select a
built-in process. The catalog starts empty and ships no executable workflow Graph.

## Strategy package and authority

Import a ZIP with `workflow.json` at its root and optional helpers under `scripts/`.
Validation precedes an immutable imported revision. Bind required slots and authorize
that exact revision before effects can run. Changing a revision requires its own
bindings and authorization. Helpers use supported runtimes already on the device;
packages do not carry interpreters.

The [definition types](../../crates/licoup-workflow/src/ir.rs) and
[compiler](../../crates/licoup-workflow/src/compile.rs) own accepted fields and Graph
validation. Runtime instances remain user data. Do not copy transition tables,
guard rules or test assertions into a second specification. The
[workflow module](../modules/workflow.md) owns the implementation boundaries and
`npm run verify:workflow`; `npm run repo:state-machines -- --list` lists providers.

## Desktop flow

1. Open **Agents → Adaptive Flywheel** and import a strategy ZIP.
2. Bind actor slots to ordered candidates, including desired fallbacks.
3. Open **Workflow** to inspect its directed transition diagram.
4. Save bindings and authorize the immutable revision.

Only a group Conversation shows the strategy capsule. Selecting an authorized
revision admits bound Agents as members; it does not start execution or rewrite
the Assistant profile. Saving that profile is separate from workflow bindings.
Turning the Assistant off affects later direct dispatch; use explicit cancellation
to stop an already running turn. It does not cancel the independent workflow.

## Agent use

The bundled [LicoUp guide](../../crates/licoup-mcp/resources/licoup-guide/SKILL.md)
explains the current conversation, delegation and workflow tools. Loading it grants
no execution authority and selects no development process or model preset. Read
capabilities from current catalogs and admitted membership profiles.

Notices carry identifiers, not worker transcripts, private paths or tool output.
They do not replace the Conversation history. Natural Agent replies remain free
form. Fallback and recovery preserve explicit session bindings and authorization;
static Graph validation does not prove live Agent availability.
