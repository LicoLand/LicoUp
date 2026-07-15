# Client Desktop

## Metadata / 元数据

- Last updated: 2026-07-10
- Status: Current maintained functionality document
- Scope: Flutter desktop client, Rust sidecar, local runtime, target adapters, MCP plugins, Skill Hub, mobile relay, client log export, snapshots, and settings.
- Staleness check: Checked against `apps/desktop/lib/src/`, `crates/lico-client-native/src/`, `crates/lico-client-native/src/core/secure_mesh.rs`, `apps/desktop/packaging.modules.json`, native-conversation driver/readiness resources, client scripts, Android device interop verifier, locked Secure Mesh decisions, and client tests on 2026-07-10.

## 模块边界

客户端是本机环境管理器。Flutter 负责展示和控制器，Rust `lico-client` 负责本机能力和 portable state。加密通信是 Lico Arc 的原生能力，自定义端到端加密协议（Secure Client Mesh）的权威在本仓库，不依赖于中转服务端或网关实现；中继只承载不透明信封。客户端不实现自治 agent loop、权限代理或服务端知识分析；本机 Source Queue、connector host、Knowledge Cache mirror、Mail scope handoff 和 MCP local bridge 只作为受控 sidecar 能力存在。网关 fabric、服务端策略与非加密协议权威仍在 core；服务端仍拥有其治理范围内的权威状态。尚未由目标协议承诺的能力必须保留 `protocol_deferred` 边界语言，不能在客户端文档中冒充已具备的目标协议能力。

## Client Priority Business Scenarios

The personal-user client usage scenarios are recorded in `docs/scenarios/personal-user/client-priority-scenarios.md`. They are active usage scenarios for the Flutter GUI, Rust sidecar, mobile client, target adapters, and Secure Client Mesh within the three-folder scenario catalog.

| Rank | Scenario | Priority rule | Shared substrate |
| --- | --- | --- | --- |
| 1 | `remote-message` | Mobile GUI sends an end-to-end encrypted message to a selected device, selected client, and selected agent conversation. | Secure Client Mesh command/result envelope plus target conversation adapter. |
| 2 | `file-sync` | A user or agent sends a selected file to a selected client and explicit destination directory. | Secure Client Mesh encrypted file manifest/chunks. |
| 3 | `skill-installer` | The desktop client installs a GitHub-hosted skill into a selected local target agent. | Skill Hub pairing, target install roots, package digest, and rollback snapshot. |
| 4 | `skill-sync` | Skill transfer follows `file-sync` until the package lands on the target device, then branches into target-agent install/activation. | `file-sync` substrate plus Skill Hub and MCP install handoff. |
| 5 | `remote-approval` | Agent approval requests are encrypted and fanned out to all trusted user clients, then resolved from any client. | Secure Client Mesh approval request/response envelope plus per-agent approval adapters. |
| 6 | `client-update` | The client downloads, verifies, and applies a signed newer version to itself. | Signed update manifest, staged downloader, and platform installer runner. |
| 7 | `agent-usage-metering` | The Agents area searches local agents, summarizes historical token usage, and labels process-metered or estimated traffic per agent. | Native history adapters, aggregate usage reports, and process network observation. |

Shared implementation constraints: device/client/conversation selectors, trust state, payload encryption, local effect execution, local activity, aggregate usage retention, target adapter capability checks, and no-plaintext verification must be reused across these scenarios. `skill-installer` owns the direct local target-agent install path; `skill-sync` reuses that install behavior only after the common encrypted file transfer has completed.

Locked production constraints from 2026-06-28: Android must implement the full pairwise + MLS protocol runtime, not only bridge/self-test proof; production transport requires a physical real-device matrix across Windows 10/11, macOS 13/14/15, Linux glibc distro families, Linux musl Alpine, x86_64/amd64, arm64/aarch64, and physical Android Phone; iOS is experimental preview only and cannot close the broad production security claim; file handoff requires local explicit confirmation and receipt with auto-preview/auto-ingestion disabled by default; the separately claimed `client-update` feature requires a complete signed auto-update channel with offline root plus online channel signing key; `agent-usage-metering` must label live process network bytes separately from estimated historical payload bytes and must not retain prompt text, completions, headers, secrets, or raw network payloads; Windows production security requires explicit owner-only ACL hardening through a native DACL helper; QR/SAS/recovery/rotation/revoke UX must be complete before the broad product security claim. These feature/security constraints do not make publisher identity, notarization, store submission, public store download, or store update/rollback evidence a prerequisite for development, ordinary builds, or GitHub Releases.

Production client evidence resources are recorded only through the redacted release proof bundle and its evidence manifest. The manifest must identify platform/architecture coverage classes, physical-device proof classes, signing/deployment proof classes, verifier commands, host-built release bundle evidence when available, and artifact digests without naming operator machines, local access paths, private hosts, credentials, or connected devices. Release signing artifacts must still document key custody, purpose separation, revocation, and rollback. Security review approval evidence and cryptographic release signing are distinct artifacts.

## 功能项 CL-01 Agents

| 项 | 设计 |
| --- | --- |
| 目标 | 发现和展示 Antigravity、Claude Code、Codex、Cursor、Copilot、Hermes、Kilo Code、Kimi Code、OpenClaw、OpenCode。 |
| 输入 | 已知路径、手动路径、目标配置文件、CLI probe、native history roots。 |
| 处理 | `lico-client` 目标 adapter 负责解析与探测，Flutter 渲染 target card。 |
| 输出 | target state、adapter capability、manual add result、配置建议。 |
| 错误 | 被动发现不启动 GUI app、不触发 login/keychain prompt、不全盘扫描 home。 |
| 验证 | `npm run client:verify:architecture`。 |

## 功能项 CL-02 MCP Plugins

| 项 | 设计 |
| --- | --- |
| 目标 | 将 LicoLite MCP 作为 peer plugin 配置到目标智能体。 |
| 输入 | target、base URL、token、config path、discovery file、state root。 |
| 处理 | `mcp config plan/apply/rollback` 只修改 LicoLite-managed 区块并创建 snapshot。 |
| 输出 | plan、applied config、snapshot id、rollback result、plugin status。 |
| 错误 | endpoint 未验证或 trust receipt 不匹配时禁止 apply，除非显式 dev override。 |
| 验证 | `npm run client:verify:architecture`, `npm run client:verify:mcp-opencode-connector`。 |

## 功能项 CL-03 Skill Hub

| 项 | 设计 |
| --- | --- |
| 目标 | 提供本地 Skill 仓库、目标配对、可见性、隐藏、版本 pin，以及从 GitHub URL 安装到选定目标 agent 的受控技能安装器。 |
| 输入 | pair request/approve/revoke/list、skill list/get、visibility、pin、`skill install plan|apply|rollback`、GitHub URL、target agent、install root override、overwrite/pin flags。 |
| 处理 | 未配对目标默认看不到技能；deny-by-default 时需要显式 reveal；安装器验证 `SKILL.md`、拒绝 symlink/path traversal、计算包 digest、只写入目标 skill root、记录 rollback snapshot。 |
| 输出 | skill list、skill detail、pairing status、install plan、install receipt、rollback snapshot id、activity record。 |
| 错误 | Skill Hub 不执行技能脚本，不安装技能依赖；GitHub 安装器只在显式 install flow 中复制验证后的技能包到目标 skill root。 |
| 验证 | `npm run client:verify:architecture`。 |

## 功能项 CL-04 Mobile Relay

| 项 | 设计 |
| --- | --- |
| 目标 | 手机通过 relay gateway 与 PC 客户端配对，把 Mobile Relay 作为 Secure Client Mesh 的兼容 transport。 |
| 输入 | gateway config、pairing code、mobile token、PC check-in、`secure_mesh.envelope` command poll/sync/complete/result。 |
| 处理 | pairing/token/lease 流程保留；生产命令队列只承载 SecureEnvelope，明文 `agent.sessions.list`、`agent.message.send` 仅可在显式开发兼容环境中使用。 |
| 输出 | pairing status、SecureEnvelope delivery metadata、encrypted result envelope、mobile relay activity。 |
| 错误 | gateway 不执行本机动作；server、GUI 和 relay store 不读取 command body、result body、error detail、file name 或 MIME。 |
| 验证 | `npm run client:verify:secure-mesh`, `npm run client:test`。 |

## 功能项 CL-05 Native History

| 项 | 设计 |
| --- | --- |
| 目标 | 只读导入各目标智能体原生会话历史，并把“关键词输入 -> 目录写入”做成端到端归档能力；Archive Profile 只是客户端内部解析和匹配模型。 |
| 输入 | 用户侧只输入一个或几个关键词和归档目录，经由 `snapshots archive collect --keywords <keywords> --path <path>` 或 GUI 单动作入口；内部/诊断入口可保留 `conversations list --agent AGENT`、`snapshots collect --topic TOPIC`、`snapshots profiles list|get|import`、`snapshots archive run|verify|report --profile PROFILE_ID`。 |
| 处理 | 归档前先复用 `targets scan` 确认本机有哪些客户端；多个关键词会被拆成多个独立 archive job 并行执行，每个 job 自己按 derived profile identity map 扫描历史、匹配、物化和验证。交互式 browse 保留安全限制。所有命中统一归档为 Conversation；adapter、宿主、JSONL/SQLite/text 等只作为内部诊断维度。 |
| 输出 | 用户侧结果是目标目录中已经写好的归档文档；关键词归档在指定目录下按每个关键词建立独立文件夹，例如 `Agent Studio` -> `agent-studio/`，不把多个关键词合成一个 collection，也不折叠到某个 lineage profile。内部产物包括 `native-history` JSON、sessions、messages、`source_client`、`host_app`、adapter id、source path、`summary.md`、`conversation-index.md`、`conversation-index.jsonl`、`sources.json`、`matches.jsonl`、`validation.json`，但健康校验和报告不应成为普通用户步骤。 |
| 错误 | `append` 和 `delete` 必须拒绝；不创建 LicoLite-local conversation database。 |
| 验证 | `cargo test --manifest-path crates/lico-client-native/Cargo.toml conversations`。 |

## Feature CL-06 Native Agent Conversation Dispatch

| Item | Design |
| --- | --- |
| Objective | Establish native-conversation parity independently for each packaged Lico Arc target adapter. With the same target identity, version, thread, working directory, model, reasoning level, permissions, and input, sending from the Lico Arc composer and sending from the target's native conversation surface must have the same observable effect. Discovery, history import, or a generic command template is not conversation support. A release may support any verified subset; completing the full inventory is a separate adapter-completeness goal. |
| Input | Agent id, message, native session/thread id and path, working directory, discovered binary and version, capability snapshot, and supported model/reasoning/permission/attachment settings. Private input must use the target's official local protocol, IPC, or stdin wherever available; prompts, local paths, credentials, and session identifiers must not enter observable argv or evidence. |
| Processing | Every agent requires a version-probed canonical conversation driver covering new-thread, exact resume, event ownership, cancellation/timeout, and native-history readback. A configured generic command is a development probe, not parity evidence. Arc must reload the real returned session id rather than guessing the newest session. Child stdout/stderr must be drained concurrently and bounded. |
| Output | Canonical protocol, real session/thread/turn ids, lifecycle status, final native assistant message, effective settings, and capability-scoped events. Consecutive structured activity is one default-collapsed process disclosure; activating it expands flat, sanitized operation rows in the same persistent item rather than creating independent cards or hiding the disclosure. A second activation collapses it. Raw chain-of-thought, tool/runtime metadata, and raw error detail never render as assistant text. Only an explicitly provider-designated reasoning summary may be shown after a second redaction pass. A native capability that Arc does not preserve keeps the adapter `partial`. |
| Error | An adapter that has not passed the core gate must have its release composer disabled instead of falling back to an older transport or silently attempting best effort. Approval requests require an explicit user approval bridge or fail closed; local machine permission is never implicit user approval. Errors are returned only as sanitized structured state. |
| Verification | Every adapter must pass deterministic driver tests, real native-vs-Arc A/B, native-history and Flutter projection checks, argv/log privacy canaries, cleanup, and release-bundle/UI verification. The existing Codex core-text evidence command, `npm run client:verify:codex-conversation:live`, is not evidence for any other adapter; canonical driver tests and synthetic E2E do not establish live readiness. |

### CL-06.1 Scope and source of truth

This document does not own another permanent adapter list. The canonical packaged set is `target-adapters.targetAdapters` in `apps/desktop/packaging.modules.json`. Runtime capabilities from `targets scan`, native-history adapters, and the Agents UI are projections of that set and must not independently redefine “conversation supported.”

The current packaged baseline comprises Antigravity, Claude Code, Codex, Cursor, Copilot, Hermes, Kilo Code, Kimi Code, OpenClaw, OpenCode, and Pi Agent. Its reducer-owned summary is `0 ready / 0 failed / 2 blocked / 9 unverified`, with zero send-enabled adapters. A future adapter enters this contract as `unverified` as soon as it is added to the canonical packaged set and exposed in the Agents conversation surface. Broad discovery-only, history-only, host-app, and unpackaged experimental targets do not automatically become conversation adapters.

| Packaged target | Canonical driver / implementation maturity | Canonical readiness |
| --- | --- | --- |
| Antigravity | `antigravity-cli`; fixed help/version probes only. The official CLI accepts non-interactive prompts and exact conversation IDs in argv and exposes no structured stdin/stream protocol. The separately distributed SDK is not a silent fallback because its authentication, storage and conversation domain are distinct. | `blocked` — `antigravity_cli_structured_transport_unavailable`. |
| Claude Code | `claude-code-stream-json`; one supervised official Streaming Input process carries every prompt through stdin NDJSON, emits partial structured events, and binds its returned native session ID to that same process for exact follow-up and interrupt. It fixes `--no-session-persistence`, never invokes argv `--resume`, and fails closed after transport loss. | `unverified` — process cleanup is complete because this lane does not persist a vendor transcript; real Release live evidence is still required before send is enabled. |
| Codex | `codex-app-server`; exact app-server thread binding, effective settings, bounded process supervision, and native-history projection are implemented. | `unverified` — canonical complete live/release evidence is absent. |
| Cursor | `cursor-acp`; one supervised official `agent acp` process receives prompts and exact session IDs only through JSON-RPC stdin, streams session-owned chunks, and resumes through `session/load`. The advertised ACP capability has no delete/close operation. | `blocked` — `safe_cleanup_unavailable`; promotion requires an official cleanup operation or a proven fully disposable data root. |
| Copilot | `copilot-acp`; ACP v1 capability negotiation, exact session ownership, fixed launch arguments, and permission fail-closed behavior are implemented. | `unverified` — canonical complete live/release evidence is absent. |
| Hermes | `hermes-acp`; one bounded supervised ACP process is retained per executable and working directory, initialized once, and reused for exact `session/load`, realtime chunks, permission fail-closed behavior, active-turn cancel, and process-tree cleanup. Native session identifiers remain on stdin. | `unverified` — the former exact-resume implementation blocker is closed; canonical complete live/release evidence is still absent. |
| Kilo Code | `kilo-code-serve`; the current path starts or attaches to the official loopback HTTP/SSE server, loads an explicit `/session/{id}`, and posts the follow-up to that same id. | `unverified` — cleanup and complete live/release UI evidence are absent. |
| Kimi Code | `kimi-code-acp`; official `kimi acp` is the only send and exact-resume transport. New sessions use `session/new`, selected sessions use exact `session/load`, chunks stream from ACP updates, and any load failure fails closed without creating a replacement session. The separate `kimi` identity belongs to the Kimi Desktop/mobile provider and is not a CLI-driver alias. | `unverified` — the canonical-driver blocker is closed; canonical complete live/release evidence is still absent. Public product cancel remains disabled until the lane owns a durable active-turn handle. |
| OpenClaw | `openclaw-acp`; the selected native Gateway session is bound through ACP metadata `sessionKey`, permission requests fail closed, and the public ACP `session/close` plus `session/list` lifecycle verifies isolated acceptance cleanup. | `unverified` — canonical complete live/release evidence is absent. |
| OpenCode | `opencode-serve`; the current path starts or attaches to the official loopback HTTP/SSE server, loads an explicit `/session/{id}`, and posts the follow-up to that same id. | `unverified` — cleanup and complete live/release UI evidence are absent. |
| Pi Agent | `pi-rpc`; official `pi --mode rpc` JSONL stdio lane binds the real session identity before prompt, streams realtime updates, resumes only an exact unique JSONL session id through `switch_session`, verifies identity after switching, and applies model selection through the official RPC. Acceptance uses a disposable session root and removes only that root. | `unverified` — the cleanup and empty-session streaming blockers are closed; real live and release-UI evidence is still absent. Independent public cancel remains unsupported because each send owns a separate RPC process. |

The implementation column is an audit aid; reducer output remains authoritative after every inventory change. The fail-closed inventory above adds structural blockers discovered after the last checked-in reduction; `agent-conversation-readiness.json` must be regenerated by the reducer before a release claim. Sending remains disabled. This table contains no machine-specific installation or account claim. A fake child, capability probe, or core-only A/B may demonstrate implementation progress but cannot change readiness.

The mobile Secure Mesh projection now binds decrypted results to the exact relay command id, encrypted payload command id, idempotency key, and command kind; it also fails closed on unresolved native-session readback. Mobile history pages through `agent.sessions.list` with `offset`/`limit` (bounded page size 20) and resolves selected older threads through `agent.sessions.describe`. Message content remains the privacy-bounded native-history projection, so a mobile release still must not claim full desktop history parity from this list/describe surface alone.

Official transport references used to classify this snapshot are informative inputs, not substitutes for live evidence: [Claude Code CLI reference](https://code.claude.com/docs/en/cli-reference), [Cursor ACP](https://cursor.com/docs/cli/acp), [GitHub Copilot CLI ACP server](https://docs.github.com/en/copilot/reference/copilot-cli-reference/acp-server), [OpenCode CLI ACP](https://opencode.ai/docs/cli/#acp), [Kilo Code CLI](https://kilo.ai/docs/code-with-ai/platforms/cli), [Kimi ACP](https://www.kimi.com/code/docs/en/kimi-code-cli/reference/kimi-acp), [Kimi CLI](https://www.kimi.com/code/docs/en/kimi-code-cli/reference/kimi-command), [OpenClaw ACP](https://docs.openclaw.ai/cli/acp), [Hermes Agent ACP](https://hermes-agent.nousresearch.com/docs/user-guide/features/acp/), [Pi Coding Agent RPC](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/rpc.md), and [Google Antigravity conversation resume](https://antigravity.google/docs/cli-conversations). Each acceptance run must probe the installed version because published capability surfaces can change.

### CL-06.2 Mandatory parity checks

Every core check is mandatory for each adapter. `blocked`, `unverified`, `not-installed`, `N/A`, and skipped are never reduced to pass.

| ID | Core dimension | Pass condition |
| --- | --- | --- |
| P-01 | Baseline binding | Native and Arc lanes use the same discovered binary/version, account or local profile, cwd, model, reasoning, permission/sandbox, proxy, and environment. Evidence records only redacted version/source classes and digests. |
| P-02 | New thread | An Arc-created turn returns a real native session/thread id. Native history reads back the user and final assistant messages, with no parallel Lico-local conversation. |
| P-03 | Exact resume | Sending to a selected native session continues that session. A concurrently newer session must not cause Arc to select “latest” instead. |
| P-04 | Final result and side effect | Deterministic text uses exact canary/schema comparison. Tool cases compare structured results and isolated file/state digests. Another LLM's subjective similarity judgment is not evidence. |
| P-05 | Effective settings | Effective cwd/model/reasoning/permission/sandbox/approval fields match. Omitted inputs must prove equivalent native sticky/default inheritance. |
| P-06 | History and rendering | Native user/assistant/tool/error order matches the Arc projection. Every contiguous structured run renders as exactly one default-collapsed process item; one click or keyboard activation expands all ordered operation rows without removing the item, and a second activation collapses it. Raw reasoning, tool arguments, and metadata do not masquerade as assistant text; provider-designated reasoning summaries and security-relevant structured semantics remain available only through sanitized detail rows. |
| P-07 | Error, cancellation, timeout | Invalid session, missing login, unavailable model, denied approval, cancellation, and timeout yield equivalent actionable states. Arc must not silently create a thread, switch models, or report false success. |
| P-08 | Privacy and process boundary | Prompts, attachments, local paths, credentials, and native ids do not appear in argv, returned stderr, activity logs, or evidence JSON. stdout/stderr are concurrently drained, bounded, and sanitized. |
| P-09 | Isolation and cleanup | Live tests use temporary workspaces/profiles/threads and clean them on success and failure. If safe deletion is unavailable, the test uses a disposable data root. Cleanup failure fails the run. |
| P-10 | Release UI path | The final run uses the sidecar packaged in the current release `.app` and covers composer -> controller -> sidecar -> native history -> Flutter renderer. Three consecutive paired UI runs pass, and every run covers both native-to-Arc and Arc-to-native directions plus the persistent collapsed/expanded process item. Debug CLI and unit tests alone cannot close this check. |

The harness performs a versioned capability probe before conditional checks. Every capability supported by the tested native version must also pass through Arc; otherwise the adapter is at most `partial`.

| ID | Conditional capability | Required comparison |
| --- | --- | --- |
| C-01 | Streaming/delta | Chunk content/order, deduplication, completion boundary, interruption state, and progressive UI rendering. |
| C-02 | Reasoning/tool trace | Reasoning visibility policy, tool call/result correlation, progress, and error ownership. Consecutive activity is summarized in one process disclosure and expands to ordered flat rows. A privacy policy may hide raw content but must not claim the native capability does not exist; only provider-designated summaries may cross the reasoning boundary. |
| C-03 | Approval | Approve, deny, cancel, and timeout bind to the same request and turn. Only an explicit user action can approve. |
| C-04 | Attachments/multimodal | Input type, order, digest, size boundary, and target-visible result for files, images, and structured input. |
| C-05 | Interrupt/steer | In-flight interrupt, subsequent steer, resume, and final thread state. |
| C-06 | Usage/status | Native turn status, usage, and completion reason retain their semantics when available; unavailable is explicit and never fabricated as zero. |

### CL-06.3 Real A/B procedure

1. Select the adapter from the canonical packaged registry and `targets scan`; record only redacted version, transport, and capability facts. `not-installed` is a host condition, not adapter pass evidence.
2. Create an isolated workspace/profile and bind binary, cwd, model, reasoning, permissions, proxy, and environment. The native lane uses the target's official conversation surface or public local protocol; the Arc lane uses the release Lico Arc conversation path. ptrace, input injection, or private-database mutation is prohibited unless the target explicitly publishes a versioned attach protocol.
3. Run both directions as one paired round: native creates then Arc resumes, and Arc creates then native resumes. Each core scenario must pass three consecutive paired rounds. Use random deterministic canaries; tool cases perform only harmless effects inside the isolated workspace.
4. Compare structured requests/effective settings, real session/turn ownership, event categories/order, final assistant output, native history/read, and Arc rendering. The native lane must not route through the Arc adapter being tested.
5. Exercise support, denial, and cancellation for every conditional capability. Record `unsupported-by-native` only from a real probe; record an Arc implementation gap as `partial`.
6. Monitor argv and evidence with privacy canaries. Output only booleans, counts, redacted version/source classes, digests, and error codes—not content, paths, session ids, accounts, raw stderr, or backend runtime data.
7. Clean temporary sessions/profiles/workspaces in `finally` and confirm cleanup through native read/list. Cleanup failure fails acceptance.
8. Produce final evidence with the release bundle. Fake drivers, Rust/Dart unit tests, and debug sidecars are prerequisite layers, not substitutes for live A/B.

### CL-06.4 Evidence and readiness

Per-adapter evidence contains at least: schema/harness version, agent id, redacted runtime version/source class, runtime protocol, capability snapshot, new-thread/resume/settings/final/history/render/error/privacy/cleanup/release booleans, `consecutivePasses`, failure stage/code, official-native-lane boolean, and evidence digest. `consecutivePasses` counts complete paired release-UI rounds, and every counted round contains both directions; a core-only or one-direction run cannot increment it. Evidence never contains prompts, responses, paths, session ids, argv text, accounts, credentials, or raw logs.

The canonical chain is:

1. `apps/desktop/packaging.modules.json` owns the packaged target set.
2. `crates/lico-client-native/resources/agent-conversation-drivers.json` binds each target to one canonical driver/protocol and declares structural blockers.
3. `crates/lico-client-native/resources/agent-conversation-evidence.json` contains only sanitized, schema-valid acceptance evidence.
4. `tools/scripts/client-agent-conversation-parity-reducer.mjs` deterministically produces and checks `agent-conversation-readiness.json`; release packaging runs the same `--check` and rejects drift or forged `ready` state.

`npm run client:verify:agent-conversation-parity` verifies the reducer contract, checked-in reduction, and synthetic ACP core harness. A synthetic harness result explicitly reports `cl06Ready: false`; it is never written as live evidence. Authorized live ACP implementation checks use `node tools/scripts/client-acp-conversation-parity.mjs --agent <id> --strict`, and the Codex core-only lane uses `npm run client:verify:codex-conversation:live`; neither command alone closes P-10 or promotes readiness. The release-UI evidence producer must bind the registry digest, driver inventory digest, capability snapshot digest, evidence digest, and the exact runtime artifact digest. Every readiness-enabled target discovery and launch revalidates that artifact; a same-name PATH executable or a different local/remote candidate cannot inherit another candidate's readiness.

| Readiness | Meaning | Release behavior |
| --- | --- | --- |
| `ready` | P-01..P-10 pass and every native-supported C-01..C-06 capability passes. | Enable the normal composer and permit a native-parity claim. |
| `partial` | Core text may pass, but at least one native capability is not equivalent. | Explicit preview only with the exact gap shown; no full-parity claim. |
| `failed` | A mandatory or applicable check was executed and failed. | Disable the release composer and expose only a sanitized failure category. |
| `blocked` | A canonical driver, official native lane, authorized test environment, or safe cleanup path is missing. | Disable the release composer; a generic command cannot bypass the block. |
| `unverified` | Evidence is missing, stale, or version-mismatched. | Disable sending by default; discovery and history can remain independent. |
| `history-only` | Only safe native-history reading/rendering is supported. | Read-only UI with no message composer. |

`not-installed` is a test-host observation rather than adapter readiness. It never advances readiness and cannot replace installed evidence from an authorized acceptance host.

Standard acceptance must provide per-agent contract, live A/B, and release-UI commands plus one reducer. Until a unified runner exists, target-specific verifiers may remain, but every supported target needs independent evidence and cannot inherit Codex results. New adapters default to `unverified`; only reducer-owned `ready` may advertise `runtime.message.send` and enable the release composer. Blocked, failed, history-only and unverified adapters remain disabled and disclosed without blocking unrelated client packaging.

## 功能项 CL-13 Agent Usage Metering

| Item | Design |
| --- | --- |
| Objective | Search supported local agents from the existing Agents area, summarize native-history token usage, and attribute traffic as `process-metered`, `history-estimated`, `mixed`, or `unavailable`. |
| Input | `lico-client agent-usage scan [--agent <id>] [--history-days <1..365>] [--timezone-offset-minutes <minutes>] [--timezone-transitions-json <json>] [--force-refresh] [--allowances-only\|--include-allowances] [--include-billing-history] [--include-target-status]`, `lico-client agent-usage report [--agent <id>] [--limit <n>]`, native history usage fields, and optional process network samples for running agents. The GUI derives a bounded transition table from the platform timezone; CLI responses are JSON. |
| Processing | The Rust sidecar keeps target/model discovery outside the default history critical path, uses a 30-local-day default window, extracts canonical explicit usage, reconciles Codex cumulative/per-event snapshots, and deduplicates active/archive copies plus inherited fork prefixes with separate normalized token and estimable-message chains scoped to the canonical fork-lineage root before window filtering. Independent sessions remain isolated, no-op events do not split identity, and explicit counters suppress matching estimates across incomplete copies. Private root-sharded SQLite/WAL caches retain complete-line append offsets, full cached-prefix generation guards, parser state, and coverage identities; schema replacement is atomic, aggregate reads use one snapshot, and indexed SQL filters the requested day window while checking global duplicate precedence. Cached and reasoning fields remain subsets. Provider allowances and dashboard credits are outside the token-history critical path. Only message ranges not covered by explicit events contribute separately labelled low-confidence estimates. |
| Output | Aggregate per-agent session/message counts aligned to the report window, prompt/cached-input/completion/total tokens, cache diagnostics with counts only, metered RX/TX bytes, estimated historical payload bytes, attribution labels, confidence/coverage labels, warnings, and newest-first bounded reports in `agent-usage-reports`. |
| Error | Unsupported process network metering returns `unavailable` instead of zero; historical traffic before observation is never presented as authoritative; reports persist aggregate process counts/byte deltas only and must not store PID/process identity, prompt text, completions, headers, secrets, or raw payloads. Legacy report schemas are retired rather than displayed or retained. |
| Verification | `npm run client:verify:agent-usage`, Flutter service/controller tests, Rust `agent_usage` tests, scenario catalog/status verifiers, and document governance checks. |

## 功能项 CL-14 Clash Proxy Bridge

| Item | Design |
| --- | --- |
| Objective | Detect local Clash Verge / Clash Verge Rev, route the client-owned `lico-client` calls through the local `mixed-port`, and create managed per-agent wrapper commands for selected agents such as Codex, Claude Code, Antigravity, OpenCode, Cursor, Copilot, Kilo Code, Kimi Code, OpenClaw, and Hermes. |
| Input | `lico-client proxy-bridge detect|status|plan|apply|rollback --targets <ids>`, optional explicit `--proxy-url`, `--mixed-port`, `--config-path`, or `--clash-dir`, and Settings UI target toggles. |
| Processing | The Rust sidecar reads common Clash Verge app/config locations, extracts `mixed-port`, TUN, `enable-process`, and `find-process-mode` signals, validates proxy URLs as loopback-only, stores client proxy environment in the `proxy-bridge` portable state collection, and writes executable wrappers under the client-owned `lico-client/proxy-bridge/wrappers` directory. The Flutter `AgentService` loads that state and injects `HTTP_PROXY`, `HTTPS_PROXY`, `ALL_PROXY`, and `NO_PROXY` into GUI-launched `lico-client` commands. |
| Output | Detection status, reachable local proxy URL, client bridge environment, generated wrapper paths, selected agent list, and a TUN Assist advisory YAML snippet with `tun`, `enable-process`, `find-process-mode`, and `PROCESS-NAME` rules. |
| Error | The client does not silently modify Clash config or subscription files, does not enable privileged TUN/network extensions, does not transparently hijack traffic, and rejects non-loopback proxy URLs. TUN Assist is advisory-only; the user must enable/authorize TUN inside Clash Verge and review the suggested rules before applying them to Clash. |
| Verification | `npm run client:verify:proxy-bridge`, Flutter service/settings tests, and Rust `proxy_bridge` tests. |

### CL-05 归档成熟度评估（2026-06-19）

本节记录一次以 OneDrive 归档桶为目标的真实归档评估。目标桶分别是 `<user-cloud-drive-root>/LicoLite/LicoLite` 和 `<user-cloud-drive-root>/LicoLite/Pactium`。该评估促成统一端到端归档模型：用户只提供关键词和目录，客户端内部为每个关键词生成 Archive Profile、并行独立执行 archive collect、写入各自的 conversation index/source inventory/validation，并只把最终归档目录作为用户侧结果。

#### 人工归档路线与客户端路线差异

| 环节 | 人工归档时应走的路线 | 当前客户端路线 | 成熟度差异 |
| --- | --- | --- | --- |
| 项目身份建模 | 先明确用户要查的关键词，并保留关键词之间的边界；例如 `LicoLite`、`OSysIt`、`Pact`、`Agent Studio`、`SplitAll` 是五个归档桶，不应被折叠成一个 LicoLite lineage 桶。 | 用户只输入一个或几个关键词；客户端为每个去重后的关键词生成内部 Archive Profile，并行独立收集对话，并在指定目录下分别写入 `<keyword-slug>/`。 | GUI 和用户侧 CLI 已收敛到 keyword-driven 入口；profile import/run 仅保留为内部/诊断能力。 |
| 历史源覆盖 | 从历史归档传统出发枚举 Codex active/archived sessions、Antigravity、Kilo、Copilot/VS Code、Cursor/Code forks、本地项目痕迹和 legacy raw stores。 | 执行归档前必须先复用客户端现有 `targets scan` 确认本机可用客户端，再按 adapter defaults、manual target history roots 和 Archive mode source diagnostics 扫描历史。 | 不应另做一套客户端发现逻辑；源覆盖仍取决于 adapter 支持范围，但 skipped/diagnostics 应由客户端内部记录。 |
| 大文件与数据库处理 | 对 JSONL/SQLite/日志做流式读取，按记录归档；大文件不能仅因体积跳过。 | Browse 模式保留 32MB/8000 文件/SQLite 2000 行交互限制；Archive mode 对 JSONL 采用流式读取，对 SQLite 采用分页读取。 | 大文件不会因为 Browse 模式限制直接排除在 profile archive 外。 |
| 选择与去重 | 使用 term/path/lineage 多信号匹配，按 archive key、source path、content fingerprint 去重，并区分命中强度。 | profile archive 记录 matched terms、confidence、archive key、content fingerprint 和 archive status；structured curation result 可补充选择。 | 客户端具备项目级召回、置信度和增量状态。 |
| 归档产物 | 产出 `summary.md`、`conversation-index.md`、`conversation-index.jsonl`、per-conversation 文件和 raw store 备份。 | profile archive 保留 snapshot layout，并新增 summary、index、sources、matches、validation 文件。 | UI 浏览和审计索引共享同一 materializer。 |
| 验证口径 | 归档后检查 duplicate、missing、stale source update、fingerprint mismatch 和 source coverage。 | 客户端在端到端归档内部执行验证；`snapshots archive verify --profile` 和 report 只能作为诊断/开发入口。 | 普通用户不应被要求单独运行 verify 或读取 report；用户侧只关心目标目录是否完成写入或收到一个明确失败。 |

#### 修复前差距与修复后实测

| 归档桶 | 修复前客户端归档 | 修复后实测归档 | 差距判断 |
| --- | --- | --- | --- |
| LicoLite: `<user-cloud-drive-root>/LicoLite/LicoLite` | `LicoLite` topic collection 物化 9 个 snapshot，全部来自 `kilo-code` 的 `source-file`，raw bytes 15,325，目录约 100K。按候选缓存做 literal topic 复核也是 9 条，但更严格的 conversation-like 记录为 0 条。 | 上一轮 `snapshots archive collect --keywords "LicoLite, OSysIt, Agent Studio, LicoLite-Deprecated"` 曾把多个关键词归并到内部 profile `licolite`，物化 126 个 conversation；该结果证明 raw export 和 Codex 解析已改善，但目录语义错误。当前纠偏后的用户侧规则是分别写入 `licolite/`、`osysit/`、`agent-studio/`、`licolite-deprecated/`。 | LicoLite 作为“多关键词查询”场景，成熟度标准不是 lineage 合并总数，而是每个输入关键词都有独立文件夹、独立索引和真实会话内容。 |
| Pactium: `<user-cloud-drive-root>/LicoLite/Pactium` | 通过 structured curation result 物化 44 个当前支持 target 的 snapshot，raw bytes 18,686,631；adapter 分布为 antigravity 40、codex 4。 | `snapshots archive collect --keywords "Pactium"` 使用严格当前项目 profile `pactium`，只匹配 `Pactium`，不把 `Pact` 等历史/弱别名自动并入；物化 86 个 Codex conversation，raw bytes 4,652,752，archive health `ok`，`source.txt` 数量为 0。 | Pactium 是“单关键词 + 当前项目严格匹配”场景，不能再和旧 `<archive-baseline-root>` 的泛 Pact/splitall/Agent Studio 混合归档直接比较。旧基线用于暴露 Codex 解析缺口；新结果用于验证严格关键词归档是否写出真实完整对话。 |

这次评估把“归档失败”定义为成熟度事实，并将修复路线落成统一端到端归档模型。完整项目归档不应要求用户使用 named profile、verify 或 report；这些是客户端内部步骤。成熟功能的外部形态必须是：用户输入关键词和目录，客户端完成本机客户端发现、内部 profile 生成、归档、验证和目录写入。

## 功能项 CL-07 Local Runtime

| 项 | 设计 |
| --- | --- |
| 目标 | 从本机 LicoLite 源码构建并托管 minimal client-local 服务端 runtime。 |
| 输入 | source root、preset config、port、runtime config、claim token。 |
| 处理 | `local-runtime ensure` 生成 runtime config、启动服务、健康检查并执行 process identity claim。 |
| 输出 | status、logs、pid、server URL、identity status。 |
| 错误 | 必须显式传入 preset config；claim token 不写入 JSON config。 |
| 验证 | `npm run client:runtime:package`, `npm run client:native:test`。 |

## 功能项 CL-08 Client Logs And Snapshots

| 项 | 设计 |
| --- | --- |
| 目标 | 记录配置写入、Skill 变化、MCP apply/rollback、relay、runtime 和状态快照；普通客户端 UI 只提供设置中的日志导出入口，不展示独立日志/快照页面。 |
| 输入 | sidecar operation result、GUI action、state store update、用户选择的日志导出路径。 |
| 处理 | portable data 写入 activity 和 snapshot；Flutter 只在 Settings 中把 activity JSONL 保存到用户选择的位置。 |
| 输出 | 导出的客户端日志 JSONL、内部 snapshot rollback material。 |
| 错误 | snapshot 不能包含 token 明文；日志导出失败只显示明确状态，不在 UI 展开原始日志内容。 |
| 验证 | `npm run client:verify:architecture`。 |

## 功能项 CL-09 Settings

| 项 | 设计 |
| --- | --- |
| 目标 | 管理服务端地址、已知路径、手动目标、本机仓库位置、偏好、外观和客户端日志导出。 |
| 输入 | GUI settings、portable data、appearance preset。 |
| 处理 | Flutter 控制器更新 portable state；sidecar 使用同一数据目录。 |
| 输出 | settings JSON、UI state、theme preference。 |
| 错误 | GUI 不直接写服务端 runtime secret。 |
| 验证 | `npm run client:test`, `npm run client:verify:architecture`。 |

## 功能项 CL-10 Source Queue And Connectors

| 项 | 设计 |
| --- | --- |
| 目标 | 用 Rust sidecar 管理本机 source item 队列、恢复提交和 connector enqueue。 |
| 输入 | `source-queue add|list|status|pause|resume|retry|cancel|drain`, `connectors list|sync|status|mirror inspect`。 |
| 处理 | Source Queue 使用 SQLite 保存状态、JSONL 保存 audit；local directory、iCloud local projection、OneDrive local projection 输出统一进入队列。 |
| 输出 | 队列 item、connector mirror、upload session/job handoff。 |
| 错误 | 无 server URL 时 drain 只 defer；mail scope 未物化时不冒充已上传。 |
| 验证 | `cargo test --manifest-path crates/lico-client-native/Cargo.toml`, `npm run client:verify:architecture`。 |

## 功能项 CL-11 Cache, Mail, And Local Bridge

| 项 | 设计 |
| --- | --- |
| 目标 | 提供 KnowledgeCore 授权 mirror、本机 Mail 显式 scope preview/export/handoff，以及 ServiceHub 可注册的 loopback MCP HTTP bridge plan。 |
| 输入 | `knowledge-cache sync|search|evidence|get|status`, `mail preview|enqueue|status|cancel`, `mcp-local-bridge plan|start|stop|status|register`。 |
| 处理 | Knowledge Cache 是 `authoritative=false` mirror；Mail 由 `lico-mail-helper` Swift sidecar 访问 macOS Mail，要求 mailbox/date/query 显式 scope，先 preview/stats，再把选中邮件物化为 `.eml` 和 `manifest.tsv` 后 enqueue；MCP bridge 只通过 client-local-runtime HTTP endpoint 暴露。 |
| 输出 | FTS search result、Mail export directory、Mail source queue item、ServiceHub registration draft。 |
| 错误 | 客户端不能声称离线 KnowledgeCore；ServiceHub 不直接启动本机 stdio。 |
| 验证 | `cargo test --manifest-path crates/lico-client-native/Cargo.toml`, `xcrun swiftc -parse-as-library apps/desktop/macos/MailHelper/LicoMailHelper.swift`, `npm run repo:client-boundary`。 |

## 功能项 CL-12 Secure Client Mesh

| 项 | 设计 |
| --- | --- |
| 目标 | 为 desktop GUI、desktop sidecar、mobile、CLI、client-local runtime、agent host 和 web_limited endpoint 提供统一 SecureEnvelope wire boundary。 |
| 输入 | `secure-mesh status`、`secure-mesh envelope validate`、`secure-mesh payload seal`、`secure-mesh payload open`、`secure-mesh command policy`、`secure-mesh command evaluate`、`secure-mesh command execute`、MobileRelayCompatibilityTransport delivery、GUI Secure Mesh status refresh、物理 Android 设备 proof JSON。 |
| 处理 | Native sidecar 校验 SecureEnvelope outer fields，提供原生 AEAD/HKDF payload seal/open binding，并让 pairwise session message key 或 MLS exporter-derived group content key 驱动 payload seal/open，执行本地 command allowlist / deny-prefix policy，并在命令 payload 解密后提供 schema、sender trust、target binding、risk、user confirmation、replay、idempotency、bounded SQLite ledger gate、本地 execution adapter 和 CLI runtime execution binding；同时提供 PC-PC/Mobile-PC/PC-Mobile/Mobile-Mobile/CLI-Desktop/client-local runtime command/result relay envelope 场景、multi-device encrypted fanout 独立 pairwise 密文副本与 ACK purge、typed encrypted result/error codec、encrypted file manifest/chunk codec 与 resume/ACK/purge state、device trust fingerprint/cross-signing/SAS/QR helper 与 policy evaluator、signed prekey/one-time prekey/KeyPackage signature-expiry-trust-low-water validator、Pactium-backed transparency verifier 目标、client-owned PQXDH + ML-KEM-1024 Triple Ratchet runtime、Sesame-style session manager、OpenMLS group add/update/remove/new-epoch wrapper、mls-rs independent Welcome join/application decrypt verifier evidence、group payload context binding 和 durable epoch metadata store/CAS/rollback/revoke tombstone，并把 Mobile Relay 默认能力限制为 `secure_mesh.envelope`。 |
| 输出 | protocol status、validated envelope metadata、sealed/opened payload metadata、本地 command policy/evaluation/execution result、desktop GUI Secure Mesh transport/readiness status、native Secure Mesh content/response/file/command/device-trust/prekey/transparency/MLS test evidence、JS/Rust sidecar wire parity evidence。 |
| 错误 | 没有已集成的 endpoint cryptographic runtime 或命令执行 adapter 时，不执行 relay envelope 内的命令 body，不把 SecureEnvelope 自动降级成明文命令。 |
| 验证 | `npm run client:verify:secure-mesh`, `npm run client:native:test`, `npm run client:test`。 |

### Secure Mesh cryptographic profile

The canonical pairwise profile is client-owned and uses X25519 classical agreement, signed
Ed25519 endpoint and prekey transcripts, FIPS 203 ML-KEM-1024, HKDF-SHA-256, a Signal-style
ML-KEM Braid sparse continuous key agreement, the Triple Ratchet, and ChaCha20-Poly1305 payload
protection. The design follows the security structure of the
[Signal PQXDH specification](https://signal.org/docs/specifications/pqxdh/), the
[Signal ML-KEM Braid specification](https://signal.org/docs/specifications/mlkembraid/), and
[NIST FIPS 203](https://csrc.nist.gov/pubs/fips/203/final). It is a Lico wire profile with its
own transcript encodings and domain-separation labels; it does not claim byte interoperability
with libsignal.

| Contract item | Canonical value |
| --- | --- |
| PQXDH suite | `licolite.pqxdh-triple-ratchet.v1.x25519-ed25519-mlkem1024-hkdfsha256` |
| Pairwise payload suite | `licolite.pqxdh-triple-ratchet.v1.x25519-ed25519-mlkem1024-hkdfsha256-chacha20poly1305` |
| ML-KEM key material | 64-byte key-generation seed, 1,568-byte encapsulation key, 3,168-byte decapsulation key, 1,568-byte ciphertext, and 32-byte shared secret |
| Incremental ML-KEM serialization | 64-byte header, 1,536-byte `ek_vector`, 1,408-byte `ct1`, and 160-byte `ct2`; the PQXDH ciphertext is `ct1 || ct2` |
| Braid wire message | Strict JSON object containing exactly `epoch`, `type`, and optional `data`; the authenticated 32-byte erasure-code chunks use GF(2^16) and the 13-transition state machine |
| Pairwise intro fields | `responderOneTimeMlKem1024PrekeyId` and `mlkem1024CiphertextBase64url`; the signed prekey bundle exposes `oneTimeMlKem1024Prekey` and never exposes its 64-byte seed |
| Relay boundary | The existing five secure-client-relay operations and six outer envelope fields remain unchanged. Pairwise, Braid, command, result, and file contents are opaque ciphertext to the relay. |

The ML-KEM-1024 parameter is compile-time bound to the `libcrux-ml-kem` incremental constants,
so an upstream size mismatch fails compilation. The executable known-answer and state-machine
vectors live in `secure_mesh_pqxdh.rs`, `secure_mesh_mlkem_braid.rs`,
`secure_mesh_sparse_pq_ratchet.rs`, and `secure_mesh_pairwise.rs`. They cover implicit rejection,
seed-to-public-key substitution, domain separation, authenticated Braid state transitions,
loss/reordering recovery, sparse cross-epoch keys, hybrid message-key derivation, replay, tamper,
and durable restart behavior.

This parameter change is intentionally non-compatible. The Secure Mesh build profile revision is
`3`, pairwise SQLite/snapshot schema is `10`, and Braid/SPQR persisted revisions are `2`. The
mobile E2EE protocol, prekey protocol, wire field names, SQLite columns, and platform secret-store
namespace all name ML-KEM-1024. State from a different profile is purged or reset and the user must
re-pair or rekey. Only the current ML-KEM-1024 profile is accepted.

当前状态：服务端 directory/delivery、客户端边界校验、JS/Rust sidecar wire parity、桌面 GUI Secure Mesh status、command execute polling、device-trust policy 与 default file route binding、Android Keystore MethodChannel runtime bridge、APK-bundled `lico-client-native` JNI native runtime self-test、物理 Android delivery-store-backed payload, endpoint signing, secure-store, runtime content-key binding, payload negative controls, Android-origin command/result proof, and app-process TLS-pinned LAN-direct probe、AEAD/HKDF payload codec、CLI payload seal/open binding、pairwise session-key payload codec、PC-PC/Mobile-PC/PC-Mobile/Mobile-Mobile/CLI-Desktop/client-local runtime command/result relay envelope 场景、server delivery store backed native command/result relay proof、multi-device encrypted fanout 独立 pairwise 密文副本与 ACK purge、MLS exporter-derived group payload codec、typed encrypted result/error codec、encrypted file manifest/chunk codec 与 resume/ACK/purge state、default encrypted file route evaluator、原生 no-plaintext canary 经 SecureEnvelope/file/Mobile Relay 路径投递验证、原生命令 schema/risk/replay/idempotency gate、bounded SQLite ledger、本地 execution adapter、CLI command execute runtime binding、device trust fingerprint/cross-signing/SAS/QR helper 与 policy evaluator、signed/one-time prekey 与 KeyPackage signature-expiry-trust-low-water validator、transparency inclusion/consistency/cached tree-head verifier、client-owned PQXDH + ML-KEM-1024 Triple Ratchet runtime、Sesame-style session manager、Cargo.lock exact-version/license allowlist、npm production audit、pinned RustSec advisory CI gate、物理 Android 设备互操作 verifier 与手动 CI 入口、OpenMLS 三端 add/update/remove/new-epoch wrapper、provider storage reload、secret-store file reload、CLI public MLS recovery vector、mls-rs 0.55.2 public-wire artifact parser、mls-rs 0.55.2 + mls-rs-crypto-openssl 0.21.0 独立 Welcome join/application decrypt runner、group payload context binding、removed-member group payload decrypt failure 和 durable epoch metadata store/CAS/rollback/revoke tombstone 已实现；广泛的产品安全与完整功能声明仍被 clean-room Signal-style pairwise audit、OpenMLS 完整跨实现恢复/解密互操作、reviewed/full Android Signal/OpenMLS protocol runtime integration、真实设备生产传输矩阵、Pactium-backed transparency migration、完整 QR/SAS/recovery/rotation/revoke UX、独立的 signed auto-update 功能、explicit Windows ACL hardening 和完整安全证据阻断。这些阻塞不包括发布者身份、公证或商店渠道，也不阻塞满足自身 artifact 校验要求的 GitHub Release。

服务端 verifier 还输出 `revokedEndpointGate`，证明被撤销 endpoint 不能继续通过 mailbox delivery、sync、ACK、file chunk、prekey 或 KeyPackage 路径参与后续互操作。

Android 物理机 verifier 现在可以显式 `--install --launch`，并在应用进程启动后读取 app-private 或 external app-specific `files/secure-mesh/android-runtime-status.json`。它要求 APK 中存在 `lib/arm64-v8a/liblico_client_native.so`，并要求 Android app 通过 JNI 加载该 Rust runtime 后完成 SecureEnvelope validation、command policy、payload crypto、pairwise runtime 和 MLS runtime status 自检，且不经 FFI 传递 secret。随后 verifier 会先在 Secure Mesh delivery store 中注册 macOS/Android endpoint，经 `cloud_relay` 向 Android mailbox 投递 macOS sidecar 生成的 encrypted challenge 和 pairwise/MLS runtime payload，sync 出 opaque envelope 后交给 Android app 打开；Android app 打开主 payload 后会在同一 app 进程内验证 wrong-context、ciphertext-tamper 和 wrong-payload-kind payload open 都被拒绝，再用 AndroidKeyStore P-256 端点签名 key 签署 endpoint challenge，用 AndroidKeyStore AES-GCM key 加密并重载 `pairwise_session` 与 `mls_group_epoch` secret-class probe；同时 Android 必须把 pairwise/MLS content key 写入 AndroidKeyStore-backed secure-store record，再用 reload 后的 content key 打开 server-delivered macOS runtime payload 并回封 Android runtime result。该 verifier 还让 Android 用 KeyStore-backed `physical_android_command` content key 封装只读 `client.activity.sync` command，经 delivery store 投递到 macOS mailbox；macOS sidecar 打开并执行本地 command gate 后，把 encrypted result 经 delivery store 投递回 Android mailbox，第二次启动 Android app 后打开该 server-delivered result。proof 不含明文 canary、raw secret 或 raw content key，macOS sidecar 会把主 Android encrypted result 经 delivery store 投递回 macOS mailbox、sync 后打开、ACK purge 两端 mailbox、扫描 persisted delivery store 无 canary，并验证 endpoint signing、secure-store、runtime-key-binding、native runtime self-test、payload negative controls 与 physical command/result evidence；同一 proof 还包含 Android app 进程 TLS-pinned transport probe transcript，当前通过 route 为 `lan_direct`，证明 Android app 进程经 WLAN 到达 macOS verifier listener，且不打开非 loopback cleartext HTTP；该证据不替代 reviewed/full Android Signal/OpenMLS protocol runtime integration 或 WebRTC 生产传输背书。
Retained local device-verification evidence is available at `build/reports/secure-mesh/device-verification-recovery/latest.json`. It ties the current Flutter relay panel, controller bindings, and native trust helpers together, but it does not claim a finished lost-device/reinstall/account-recovery flow or a physical-device E2E run.
