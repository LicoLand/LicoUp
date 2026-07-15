# Skill Installer Scenario

## Metadata / 元数据

- Last updated: 2026-06-28
- Status: Active personal-user usage scenario
- Scope: Direct desktop-client installation of a GitHub-hosted Codex-style skill into a selected local agent target.
- Staleness check: Checked against the Flutter Skill Hub panel, `AgentService` CLI bindings, Rust `skill install` commands, target adapter capabilities, and local evidence verifier on 2026-06-28.

## `skill-installer`

Goal: a user opens the desktop client, chooses a local target agent, pastes a GitHub URL for a skill repository or skill subdirectory, previews the install plan, and installs the validated skill into the selected agent's skill directory with rollback available.

| Planning area | Complete plan |
| --- | --- |
| User path | The Skill Hub panel exposes target-agent selection, GitHub URL input, optional skill id override, optional install root override, overwrite and pin controls, preview, install, result, and rollback snapshot action. |
| Native command | `lico-client skill install plan --agent <agent> --url <github-url>` resolves source metadata, target install root, package digest, file count, conflict status, and install directory. `lico-client skill install apply` performs the write. `lico-client skill install rollback` restores the captured directory snapshot. |
| Source package | The sidecar accepts `github.com/<owner>/<repo>` URLs and `tree` or `blob` subdirectory URLs. The verifier also supports `--source-path <path>` so offline local evidence can exercise the same package validation and install path without network dependency. |
| Target adapter | Built-in install roots are exposed for `codex` and `claude-code`; other targets can be used only when the caller provides an explicit install root. Target scanning advertises `skill.install` for supported adapters. |
| Package validation | A package must contain `SKILL.md`. The sidecar reads frontmatter metadata, normalizes the skill id, rejects symlinks, computes a deterministic SHA-256 digest over regular files, and keeps all writes inside the resolved install root. |
| Local effect | Install writes a temporary copy, atomically moves it into the target skill root, records a rollback snapshot, creates a Skill Hub skill record, reveals it for the selected paired agent, optionally pins the version, and writes activity. |
| GUI | Flutter delegates all install work to the sidecar. It stores only plan/result state, displays the selected target and install receipt, and refreshes visible skills after apply or rollback. |
| Security | Preview and install never execute transferred skill code, never install dependencies, reject path traversal and symlinks, require an approved Skill Hub pairing, and keep rollback available for the touched skill directory. |
| Verification | `npm run client:verify:architecture` and focused Flutter/native tests cover the same sidecar command path, target `skill.install` support, visible skill and pin state, rollback, and local report output. |
| Parallel work packages | Native GitHub package resolver and installer; target adapter install capability; Flutter service/controller/UI actions; scenario catalog/status updates; offline local verifier; client analyzer and controller tests. |
| Completion condition | A user can paste a GitHub skill URL, choose a target agent, preview the package digest and install directory, install the skill, see it in the selected agent's visible Skill Hub list, optionally pin it, and roll back the installation without executing the skill during preview or install. |
