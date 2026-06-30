# Personal User Client Scenarios

Status: active personal-user usage-scenario ledger

This document records the client-facing usage scenarios for desktop and mobile users. It is the personal-user category document in the scenario catalog; the canonical client functionality pointer is `docs/functionality/CLIENT-DESKTOP.md`.

These are usage scenarios with acceptance conditions, not a release plan. The work packages under each scenario are designed to run in parallel where ownership permits. `skill-installer` is the direct local GitHub-to-agent install path; `skill-sync` reuses the same target install behavior after encrypted device-to-device transfer.

Locked constraints from the 2026-06-28 E2EE decisions: pairwise production uses a clean-room implementation aligned to Signal-style best practices and does not add a new external pairwise protocol dependency; Android must carry the full pairwise + MLS protocol runtime; transport production needs a real physical device matrix across Windows 10/11, macOS 13/14/15, Linux glibc distro families, Linux musl Alpine, x86_64/amd64, arm64/aarch64, and physical Android Phone; iOS is experimental preview only; file handoff requires local explicit confirmation and receipt with auto-preview/auto-ingestion disabled by default; `client-update` requires complete signed auto-update with offline root plus online channel signing key; Windows production requires explicit owner-only ACL hardening through a native DACL helper; recovery UX must cover QR/SAS/recovery/rotation/revoke; product-line delivery is all-or-nothing for this `personal-user` group; full release readiness requires all catalog scenarios verified.

Confirmed evidence resources for this product line: Windows 11 x86_64 runs on the current workstation; Linux x86_64 runs in a VM on the current workstation; macOS arm64 runs on an Apple Silicon Mac; Linux arm64 runs in a VM on that Mac; physical Android proof uses the Android test phone connected to the current Windows workstation. `client-update` production signing and deployment evidence uses the `<app-domain>` server reachable from the local machine by SSH plus the available cloud/domain-certificate signing resource; local temporary signing is not enough for production evidence.

## Priority Order

| Rank | Scenario | User-facing outcome | Primary substrate |
| --- | --- | --- | --- |
| 1 | `remote-message` | A phone client sends a message to a selected device, target client, and target agent conversation. | Secure Client Mesh command/result envelope |
| 2 | `file-sync` | A client or agent transfers a selected local file to a selected client and destination directory. | Secure Client Mesh encrypted file manifest/chunks |
| 3 | `skill-installer` | A desktop client installs a GitHub-hosted skill into a selected local target agent. | Skill Hub pairing, target install roots, package digest, and rollback snapshot |
| 4 | `skill-sync` | A user or agent syncs a skill from one agent/client context into another agent. | `file-sync` substrate plus Skill Hub/MCP install handoff |
| 5 | `remote-approval` | Approval requests from agents appear on all user clients and can be answered remotely. | Secure Client Mesh approval envelope plus per-agent adapters |
| 6 | `client-update` | A client discovers, downloads, verifies, and applies a newer client release. | Signed update manifest and platform installer runner |
| 7 | `agent-usage-metering` | A client searches local agents, summarizes historical token usage, and attributes process-metered or estimated traffic. | Native history adapters plus process network metering samples |

## Shared Client Substrate

The seven scenarios share the client primitives defined in `shared-client-substrate.md`. Scenario-specific implementations must reuse that substrate for addressing, trust, encrypted payloads, delivery, local effects, activity, usage metering, and negative controls.

## `remote-message`

Goal: the user opens the mobile client, chooses a paired target device, chooses a target client/agent on that device, chooses a specific conversation, writes a message, and sends it. The target client decrypts the payload locally and forwards the message into the selected agent conversation.

| Planning area | Complete plan |
| --- | --- |
| User path | GUI exposes a device picker, target client picker, agent/conversation picker, message composer, send state, delivery state, target-open state, agent-forward state, and encrypted result/error state. The user only needs to decide where the message goes and what the message says. |
| Protocol | Define `secure_mesh.command.remote_message.v1` with encrypted fields for message text, target agent id, target conversation id, optional attachments refs, sender display metadata, idempotency key, and requested result policy. Outer envelope keeps only routing and ciphertext size. |
| Sender client | Mobile/desktop sidecar builds target context from roster plus local known target catalog, validates recipient trust, seals payload with pairwise or MLS-derived content key, queues via Secure Mesh, and records activity without plaintext. |
| Receiving client | Sidecar opens payload, checks sender trust, target binding, conversation capability, replay/idempotency, and agent adapter availability. It forwards the message through the adapter-specific conversation send API or CLI bridge and seals a result envelope back to the sender. |
| Agent adapters | Add adapter contracts for `conversation.list`, `conversation.describe`, and `conversation.message.send`. Each target adapter declares whether it can address existing conversations, create a new conversation, or only accept unsupported/no-op status. |
| GUI | Add conversation search/filter, stale target refresh, trust warning, delivery timeline, retry/cancel, and result detail. The UI must not show server-visible decrypted payload from remote storage; decrypted text appears only in local sender/receiver views where appropriate. |
| Security | Wrong recipient, stale roster, revoked endpoint, changed key, unsupported conversation id, replayed message id, and failed adapter policy all fail closed. Message body and target conversation detail are never logged by server or relay. |
| Verification | Add a desktop-to-desktop and mobile-to-desktop verifier that sends an encrypted canary message into a mock/real target conversation adapter, confirms the target adapter receives plaintext only after local decrypt, returns encrypted result, ACK-purges mailboxes, and scans server stores for canary absence. |
| Parallel work packages | GUI target/conversation picker; native command schema and payload codec; server delivery verifier fixtures; agent adapter conversation contract; mobile sender flow; desktop receiver handoff; local activity model; no-plaintext and wrong-recipient tests. |
| Completion condition | A phone can send to a selected device/client/conversation, the receiving client forwards into that exact conversation, the sender sees delivery/result state, and the server cannot read the message or conversation content. |

## `file-sync`

Goal: a user or agent transfers a selected file from one client to another client and writes it into an explicitly selected destination directory on the receiving device. This scenario precedes `skill-sync` because it provides the common encrypted file movement substrate.

| Planning area | Complete plan |
| --- | --- |
| User path | GUI exposes source file picker, target device/client picker, destination directory picker or validated typed path, transfer options, progress, receive confirmation policy, conflict handling, and completion receipt. Agent-triggered transfer uses the same substrate but must provide source file and destination directory in the request. |
| Protocol | Define `secure_mesh.file_sync.v1` with encrypted manifest fields for file name, MIME, source relative path, target destination directory, file size, chunk count, chunk hashes, conflict mode, transfer id, and requested confirmation policy. Chunks use encrypted file chunk payloads with resume state. |
| Sender client | Sidecar validates source file path boundaries, chunks and encrypts content, sends encrypted manifest and chunks, tracks resume gaps, and records activity with hashes and sizes only. |
| Receiving client | Sidecar opens manifest, validates destination directory against user-approved roots, asks for confirmation when policy requires it, handles conflict modes, writes to a temp file, verifies chunk integrity, atomically moves into destination, ACKs, and returns encrypted receipt. The local verifier requires this exact handoff behavior: asks for confirmation when policy requires it, handles conflict modes, writes to a temp file, verifies chunk integrity, atomically moves into destination, ACKs, and returns encrypted receipt. |
| Agent trigger | MCP/sidecar tool request can initiate file transfer only with explicit allowed source path and target destination. High-risk paths, hidden directories, and executable overwrite requests require policy denial or user approval. |
| GUI | Add source and destination selection, transfer queue, per-transfer progress, resume/retry/cancel, conflict resolution, and received-file reveal. Destination path must be visible before send and before final write. |
| Security | File name, MIME, relative path, destination directory, and file bytes stay encrypted. Receiver enforces local path boundary and never trusts sender-provided absolute paths. Wrong-recipient chunks, duplicate chunks with conflicting hashes, expired transfers, and revoked endpoints fail closed. |
| Verification | Add verifier for mobile-to-desktop and desktop-to-desktop transfer with multi-chunk canary file, resume gap, conflict mode, destination-boundary rejection, ACK purge, and no server plaintext scan for file name, MIME, destination directory, and content. |
| Parallel work packages | Shared file manifest schema; chunk encrypt/resume implementation; path-boundary and conflict policy; GUI source/destination flow; MCP/agent trigger contract; transfer queue/activity model; server store no-plaintext verifier; platform-specific file picker/writer tests. |
| Completion condition | A user can send a selected file to a selected client directory, an agent can request the same transfer under policy, resume works, conflict behavior is explicit, and server storage never sees file metadata or bytes in plaintext. |

## `skill-installer`

Goal: a desktop user installs a GitHub-hosted skill into a selected local target agent from the Skill Hub panel. This scenario is the direct local install path; `skill-sync` reuses the same install behavior after encrypted cross-client package delivery.

| Planning area | Complete plan |
| --- | --- |
| User path | GUI exposes target-agent selection, GitHub URL input, optional skill id override, optional install root override, overwrite and pin controls, install preview, install result, visible-skill refresh, and rollback snapshot action. |
| Native command | `lico-client skill install plan|apply|rollback` accepts an approved paired agent, GitHub URL, optional install root, optional skill id override, overwrite flag, and pin flag. |
| Source package | The sidecar accepts `github.com/<owner>/<repo>` URLs and tree/blob subdirectory URLs, clones the selected ref, and validates the package directory. Offline local evidence uses `--source-path` with the same validation/install path. |
| Target adapter | Codex and Claude Code have built-in skill roots; other targets require an explicit install root. Target scan exposes `skill.install` for adapters with built-in support. |
| Safety | The package must contain `SKILL.md`; symlinks and path traversal are rejected; preview and install never execute skill code or install dependencies; writes stay inside the selected skill root. |
| Local effect | Apply writes the package through a temporary directory, records a rollback snapshot, adds a Skill Hub skill record, reveals the skill for the selected agent, optionally pins its version, and records activity. |
| GUI | Flutter keeps the flow in Skill Hub, delegates filesystem and GitHub work to the sidecar, displays plan/result fields, and refreshes visible skills after apply or rollback. |
| Verification | `npm run client:verify:skill-installer`, Flutter service/controller tests, native `skill_install` tests, and target capability tests cover CLI registration, install plan/apply/rollback, visible skill state, pin state, and rollback cleanup. |
| Parallel work packages | Native GitHub resolver and package installer; target adapter capability registry; Flutter service/controller/panel controls; scenario doc/status/catalog updates; local evidence verifier. |
| Completion condition | A user can paste a GitHub skill URL, choose a target agent, preview the digest and install directory, install the skill, see it in the selected agent's visible Skill Hub list, optionally pin it, and roll it back without executing the skill during preview or install. |

## `skill-sync`

Goal: a user or agent syncs a skill from one agent/client context to another agent. The transfer path is the same as `file-sync` until the skill package lands on the receiving device; then the receiving client validates and installs it into the target agent's skill directory or declared skill registry.

| Planning area | Complete plan |
| --- | --- |
| User path | GUI exposes source skill selection, target device/client/agent picker, install destination preview, compatibility checks, diff/overwrite policy, manual sync button, and install result. Agent-initiated sync uses MCP service operations to request the same package transfer and install handoff. |
| Protocol | Define `secure_mesh.skill_sync.v1` as an encrypted manifest layered on file-sync. It includes skill id, version, source agent, target agent, package digest, declared files, install strategy, compatibility metadata, and optional activation request. |
| Sender client | Sidecar packages selected skill files, validates manifest shape, signs or fingerprints package metadata where available, then uses the file-sync substrate to deliver the encrypted package. |
| Receiving client | Sidecar opens package, verifies digest and manifest, checks target adapter install support, previews file writes, installs only into target-owned skill location, records rollback snapshot, optionally activates/pins, and sends encrypted install receipt. The local verifier requires package digest, install destination preview, rollback snapshot, optionally activates/pins, and sends encrypted install receipt. |
| MCP entry | LicoLite MCP exposes plan/request/status operations so an agent can ask for skill sync without direct filesystem access. The MCP path creates a governed request; local client still performs device transfer and install. |
| GUI | Add skill source browser, target compatibility badge, install preview, diff summary, activation/pin controls, rollback action, and history. Manual sync and agent-requested sync share the same confirmation UI. |
| Security | A skill package is data until the receiving target adapter installs it. No transferred skill executes during transit or preview. Target adapter path boundaries, package manifest validation, denied executable hooks, and rollback snapshot are mandatory. |
| Verification | Add verifier that syncs a sample skill between two local target adapters through encrypted file-sync, confirms package digest, install path, rollback snapshot, target visibility, MCP request path, and no plaintext package content in server delivery store. |
| Parallel work packages | Reuse file-sync substrate; skill package manifest/digest builder; target adapter install contracts; MCP plan/request/status tools; GUI source/target/install preview; rollback and activation state; install verifier and package safety tests. |
| Completion condition | A user can sync a skill between selected agents, an agent can request sync through MCP, the target client installs only after local validation/confirmation, rollback is available, and transfer-before-install is fully encrypted. |

## `remote-approval`

Goal: when an agent action needs approval, the request appears in real time on all user clients. The user can approve or deny from any trusted client, and the result is returned to the waiting agent through an encrypted approval response.

| Planning area | Complete plan |
| --- | --- |
| User path | GUI shows live approval inbox, requester agent, target device/client, operation summary, risk level, timeout, requested files/tools, allow/deny controls, and final result. All active user clients receive the same pending approval state. |
| Protocol | Define `secure_mesh.approval_request.v1` and `secure_mesh.approval_response.v1` with encrypted operation detail, policy reason, display summary, pending operation id, adapter callback token reference, expiry, and response decision. |
| Agent adapters | Each agent target needs an approval bridge that can detect pending approval, pause or observe the operation, serialize an approval request, and resume/deny according to the returned response. Adapters may differ, so each declares capability and callback semantics. |
| Client fanout | The origin client or local runtime seals approval requests to all trusted user endpoints. The first valid response wins according to pending-operation CAS; later responses show resolved state. |
| GUI | Add approval inbox, push/live refresh, detail drawer, risk badges, expired/resolved state, response history, multi-client conflict handling, and settings for notification policy. |
| Security | Approval content, files, prompts, and tool arguments stay encrypted. A response must bind to pending operation id, requesting agent, target client, user endpoint, expiry, and one-time response nonce. Changed trust state or revoked endpoint invalidates open approvals. |
| Verification | Add adapter fixtures for at least two target styles: a callback-based agent and a polling/CLI-style agent. Verify all clients receive encrypted request, one client resolves it, waiting operation resumes or denies, duplicate response is rejected, expired request fails closed, and server store has no plaintext approval detail. |
| Parallel work packages | Approval payload schemas; pending-operation CAS and idempotency; per-agent adapter bridges; multi-client fanout; GUI inbox/notifications; encrypted response return path; duplicate/expiry/revoke tests; no-plaintext verifier. |
| Completion condition | A real pending agent operation can be approved or denied from any trusted client, all clients converge on the resolved state, adapter-specific resume works, and approval details are never server-readable. |

## `client-update`

Goal: the client can detect a newer release, download it, verify it, and apply the update to itself with platform-safe rollback behavior.

| Planning area | Complete plan |
| --- | --- |
| User path | GUI shows current version, channel, available version, release notes, download progress, signature/checksum state, install readiness, restart requirement, and rollback status. Policy can allow manual-only or automatic-download/manual-install. |
| Manifest | Publish a signed update manifest per channel with version, platform, architecture, artifact URL, size, SHA-256, signature, minimum supported version, migration notes, release notes URL, and mandatory/optional classification. |
| Downloader | Sidecar downloads to a staging directory, supports resume, verifies size/hash/signature before install, prevents downgrade unless explicitly allowed by signed policy, and never executes a partially downloaded artifact. |
| Installer | Platform runners handle macOS app replacement, Windows installer/MSIX or portable replacement, Linux AppImage/deb/rpm/tar strategy, and Android APK/update channel if supported. Each runner records pre-update state and rollback feasibility. |
| GUI | Add update settings, update check, release details, progress, install/restart prompt, failure remediation, and rollback view. |
| Security | Update metadata and artifacts require signature verification. TLS alone is insufficient. Manifest key rotation must be explicit. Staged artifacts live in restricted directories and are removed on success/failure according to retention policy. |
| Verification | Add manifest signature tests, checksum mismatch rejection, interrupted download resume, downgrade rejection, unsupported-platform handling, staging cleanup, platform dry-run install plan, and local smoke check after update runner dry-run. |
| Parallel work packages | Release manifest generator; signature verification in sidecar; platform installer runners; GUI update panel; download/resume/staging store; version/channel policy; rollback records; update verifier and release CI artifact checks. |
| Completion condition | A client can safely update itself from a signed release channel, rejects tampered or unsupported artifacts, gives clear user control, and leaves a rollback or recovery path where the platform allows it. |

## `agent-usage-metering`

Goal: the desktop client searches all locally supported agents, reads native history where available, summarizes historical token usage, and shows traffic attribution for each agent without retaining prompts, completions, headers, secrets, or raw payload bytes.

| Planning area | Complete plan |
| --- | --- |
| User path | GUI exposes an Agents-area usage panel with scan and process-observation actions, per-agent token totals, session/message counts, metered RX/TX bytes, estimated historical payload bytes, attribution, and confidence labels. |
| Native command | `lico-client agent-usage scan --json [--agent <id>] [--observe-ms <ms>]` scans the current target catalog and native histories. `lico-client agent-usage report --json [--agent <id>] [--limit <n>]` lists retained aggregate reports. |
| Token model | Sidecar extracts explicit usage fields such as prompt/input, completion/output, total, and cache input tokens when native histories expose them. If explicit usage is missing, it uses a low-confidence text estimate and labels the source breakdown. |
| Process traffic | Process network metering is authoritative only for running agent processes observed while the meter is active and the platform provider can supply per-process counters or samples. Past traffic before observation is not reconstructed; it is shown only as estimated historical payload bytes. |
| Persistence | Portable state retains bounded aggregate reports under `agent-usage-reports`. It stores metrics, timestamps, process identity, source labels, and counts only; it does not store prompt text, completion text, request headers, secrets, or raw network payloads. |
| GUI | The feature stays inside the existing Agents module. It does not add a new shell module and does not read local files directly from Flutter; Flutter delegates scan/report calls to the sidecar CLI. |
| Security | Unsupported process network providers return `unavailable`, not zero. PID reuse is guarded by process name/start identity when samples are present. Secret and prompt canaries must be absent from usage reports. |
| Verification | `npm run client:verify:agent-usage`, Flutter service/controller tests, native `agent_usage` tests, and scenario catalog/status verifiers cover command registration, usage extraction, process-sample deltas, report retention, UI wiring, and documentation linkage. |
| Parallel work packages | Native usage parser and process sample contract; CLI command registration; Flutter service/controller/UI panel; usage report retention; scenario docs/catalog/status updates; verifier and test registration. |
| Completion condition | A user can scan all local supported agents from the Agents area, see token and traffic attribution per agent, distinguish process-metered bytes from historical estimates, and confirm the report contains aggregate metrics only. |

## Cross-Scenario Parallelization Map

| Work package | Helps scenarios |
| --- | --- |
| Device/client/conversation selector and roster cache | `remote-message`, `file-sync`, `skill-sync`, `remote-approval` |
| SecureEnvelope command schema registry | `remote-message`, `remote-approval`, `file-sync`, `skill-sync` |
| Encrypted file manifest/chunk transfer queue | `file-sync`, `skill-sync` |
| Target agent adapter capability registry | `remote-message`, `skill-installer`, `skill-sync`, `remote-approval`, `agent-usage-metering` |
| Native history adapters and local history diagnostics | `remote-message`, `agent-usage-metering` |
| GUI activity timeline and retry/cancel controls | all seven scenarios |
| No-plaintext, wrong-recipient, replay, revoked-endpoint verifier fixtures | Secure Mesh scenarios: `remote-message`, `file-sync`, `skill-sync`, `remote-approval` |
| Platform path boundary and atomic local write helpers | `file-sync`, `skill-installer`, `skill-sync`, `client-update` |
| GitHub skill package validation and rollback records | `skill-installer`, `skill-sync` |
| Signed manifest, digest, and rollback records | `skill-sync`, `client-update` |
| Aggregate metrics and process attribution labels | `agent-usage-metering` |
