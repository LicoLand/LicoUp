# Client Desktop

## Metadata / 元数据

- Last updated: 2026-06-28
- Status: Current maintained functionality document
- Scope: Flutter desktop client, Rust sidecar, local runtime, target adapters, MCP plugins, Skill Hub, model forwarding, mobile relay, activity, snapshots, and settings.
- Staleness check: Checked against `apps/desktop/lib/src/`, `crates/lico-client-native/src/`, `crates/lico-client-native/src/commands/secure_mesh.rs`, `apps/desktop/packaging.modules.json`, client scripts, Android device interop verifier, locked Secure Mesh decisions, and client tests on 2026-06-28.

## 模块边界

客户端是本机环境管理器。Flutter 负责展示和控制器，Rust `lico-client` 负责本机能力和 portable state。客户端不实现自治 agent loop、权限代理或服务端知识分析；本机 Source Queue、connector host、Knowledge Cache mirror、Mail scope handoff 和 MCP local bridge 只作为受控 sidecar 能力存在，服务端仍拥有治理与权威状态。尚未由目标协议承诺的能力必须保留 `protocol_deferred` 边界语言，不能在客户端文档中冒充已具备的目标协议能力。

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

Locked production constraints from 2026-06-28: Android must implement the full pairwise + MLS protocol runtime, not only bridge/self-test proof; production transport requires a physical real-device matrix across Windows 10/11, macOS 13/14/15, Linux glibc distro families, Linux musl Alpine, x86_64/amd64, arm64/aarch64, and physical Android Phone; iOS is experimental preview only and cannot close production; file handoff requires local explicit confirmation and receipt with auto-preview/auto-ingestion disabled by default; `client-update` requires a complete signed auto-update channel with offline root plus online channel signing key; `agent-usage-metering` must label live process network bytes separately from estimated historical payload bytes and must not retain prompt text, completions, headers, secrets, or raw network payloads; Windows production requires explicit owner-only ACL hardening through a native DACL helper; QR/SAS/recovery/rotation/revoke UX must be complete before production readiness. The client product line can be delivered independently only when every `personal-user` scenario is `verified` with empty blockers; `remote-message`, `file-sync`, `skill-installer`, `skill-sync`, `remote-approval`, `client-update`, and `agent-usage-metering` cannot ship as a mixed intermediate state.

Confirmed client evidence resources: Windows 11 x86_64 is verified on the current workstation, Linux x86_64 in a VM on that workstation, macOS arm64 on an Apple Silicon Mac, Linux arm64 in a VM on that Mac, and Android arm64 on the physical test phone connected to the current Windows workstation. Production signing/deployment evidence for client update uses the `<app-domain>` server reachable by local SSH plus the available cloud/domain-certificate signing resource; release signing artifacts must still document key custody, purpose separation, revocation, and rollback. Security review approval evidence and cryptographic release signing are distinct artifacts.

## 功能项 CL-01 Agents

| 项 | 设计 |
| --- | --- |
| 目标 | 发现和展示 Antigravity、Claude Code、Codex、Cursor、GitHub Copilot、Hermes Agent、Kilo Code、OpenClaw、OpenCode。 |
| 输入 | 已知路径、手动路径、目标配置文件、CLI probe、native history roots。 |
| 处理 | `lico-client` 目标 adapter 负责解析与探测，Flutter 渲染 target card。 |
| 输出 | target state、adapter capability、manual add result、配置建议。 |
| 错误 | 被动发现不启动 GUI app、不触发 login/keychain prompt、不全盘扫描 home。 |
| 验证 | `npm run client:verify:targets`。 |

## 功能项 CL-02 MCP Plugins

| 项 | 设计 |
| --- | --- |
| 目标 | 将 LicoLite MCP 作为 peer plugin 配置到目标智能体。 |
| 输入 | target、base URL、token、config path、discovery file、state root。 |
| 处理 | `mcp config plan/apply/rollback` 只修改 LicoLite-managed 区块并创建 snapshot。 |
| 输出 | plan、applied config、snapshot id、rollback result、plugin status。 |
| 错误 | endpoint 未验证或 trust receipt 不匹配时禁止 apply，除非显式 dev override。 |
| 验证 | `npm run client:verify:mcp-plugins`, `npm run client:verify:mcp-opencode-connector`。 |

## 功能项 CL-03 Skill Hub

| 项 | 设计 |
| --- | --- |
| 目标 | 提供本地 Skill 仓库、目标配对、可见性、隐藏、版本 pin，以及从 GitHub URL 安装到选定目标 agent 的受控技能安装器。 |
| 输入 | pair request/approve/revoke/list、skill list/get、visibility、pin、`skill install plan|apply|rollback`、GitHub URL、target agent、install root override、overwrite/pin flags。 |
| 处理 | 未配对目标默认看不到技能；deny-by-default 时需要显式 reveal；安装器验证 `SKILL.md`、拒绝 symlink/path traversal、计算包 digest、只写入目标 skill root、记录 rollback snapshot。 |
| 输出 | skill list、skill detail、pairing status、install plan、install receipt、rollback snapshot id、activity record。 |
| 错误 | Skill Hub 不执行技能脚本，不安装技能依赖；GitHub 安装器只在显式 install flow 中复制验证后的技能包到目标 skill root。 |
| 验证 | `npm run client:verify:pairing-skill-cli`, `npm run client:verify:skill-installer`。 |

## 功能项 CL-04 Model Forwarding

| 项 | 设计 |
| --- | --- |
| 目标 | 管理薄模型转发 profile，转发请求而不构建 agent harness。 |
| 输入 | profile id、command/url、args、api key、timeout、request text。 |
| 处理 | sidecar 保存脱敏 profile，执行一次薄调用并返回结果。 |
| 输出 | profile list、forwarding result、activity。 |
| 错误 | 不保存 planner、tool chooser、memory 或隐藏 scratchpad 字段。 |
| 验证 | `npm run client:verify:thin-forwarding`。 |

## 功能项 CL-05 Mobile Relay

| 项 | 设计 |
| --- | --- |
| 目标 | 手机通过 relay gateway 与 PC 客户端配对，把 Mobile Relay 作为 Secure Client Mesh 的兼容 transport。 |
| 输入 | gateway config、pairing code、mobile token、PC check-in、`secure_mesh.envelope` command poll/sync/complete/result。 |
| 处理 | pairing/token/lease 流程保留；生产命令队列只承载 SecureEnvelope，明文 `agent.sessions.list`、`agent.message.send` 仅可在显式开发兼容环境中使用。 |
| 输出 | pairing status、SecureEnvelope delivery metadata、encrypted result envelope、mobile relay activity。 |
| 错误 | gateway 不执行本机动作；server、GUI 和 relay store 不读取 command body、result body、error detail、file name 或 MIME。 |
| 验证 | `npm run client:verify:secure-mesh`, `npm run client:test`, `npm run client:native:test`。 |

## 功能项 CL-06 Native History

| 项 | 设计 |
| --- | --- |
| 目标 | 只读导入各目标智能体原生会话历史，并把“关键词输入 -> 目录写入”做成端到端归档能力；Archive Profile 只是客户端内部解析和匹配模型。 |
| 输入 | 用户侧只输入一个或几个关键词和归档目录，经由 `snapshots archive collect --keywords <keywords> --path <path>` 或 GUI 单动作入口；内部/诊断入口可保留 `conversations list --agent AGENT`、`snapshots collect --topic TOPIC`、`snapshots profiles list|get|import`、`snapshots archive run|verify|report --profile PROFILE_ID`。 |
| 处理 | 归档前先复用 `targets scan` 确认本机有哪些客户端；多个关键词会被拆成多个独立 archive job 并行执行，每个 job 自己按 derived profile identity map 扫描历史、匹配、物化和验证。交互式 browse 保留安全限制。所有命中统一归档为 Conversation；adapter、宿主、JSONL/SQLite/text 等只作为内部诊断维度。 |
| 输出 | 用户侧结果是目标目录中已经写好的归档文档；关键词归档在指定目录下按每个关键词建立独立文件夹，例如 `Agent Studio` -> `agent-studio/`，不把多个关键词合成一个 collection，也不折叠到某个 lineage profile。内部产物包括 `native-history` JSON、sessions、messages、`source_client`、`host_app`、adapter id、source path、`summary.md`、`conversation-index.md`、`conversation-index.jsonl`、`sources.json`、`matches.jsonl`、`validation.json`，但健康校验和报告不应成为普通用户步骤。 |
| 错误 | `append` 和 `delete` 必须拒绝；不创建 LicoLite-local conversation database。 |
| 验证 | `cargo test --manifest-path crates/lico-client-native/Cargo.toml conversations`。 |

## 功能项 CL-13 Agent Usage Metering

| Item | Design |
| --- | --- |
| Objective | Search supported local agents from the existing Agents area, summarize native-history token usage, and attribute traffic as `process-metered`, `history-estimated`, `mixed`, or `unavailable`. |
| Input | `lico-client agent-usage scan --json [--agent <id>] [--observe-ms <ms>]`, `lico-client agent-usage report --json [--agent <id>] [--limit <n>]`, native history usage fields, and optional process network samples for running agents. |
| Processing | The Rust sidecar reuses target discovery and native history adapters, extracts explicit prompt/input and completion/output usage when present, falls back to low-confidence text estimates when token fields are missing, computes estimated historical payload bytes, and applies process network deltas only for observed running processes. |
| Output | Aggregate per-agent session/message counts, prompt/completion/total tokens, metered RX/TX bytes, estimated historical payload bytes, attribution labels, confidence labels, warnings, and bounded retained reports in `agent-usage-reports`. |
| Error | Unsupported process network metering returns `unavailable` instead of zero; historical traffic before observation is never presented as authoritative; reports must not store prompt text, completions, headers, secrets, or raw payloads. |
| Verification | `npm run client:verify:agent-usage`, Flutter service/controller tests, Rust `agent_usage` tests, scenario catalog/status verifiers, and document governance checks. |

### CL-06 归档成熟度评估（2026-06-19）

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
| 目标 | 使用客户端仓库内置 runtime 模板构建并托管 minimal client-local runtime。 |
| 输入 | port、runtime config、claim token。 |
| 处理 | `local-runtime ensure` 生成客户端 runtime package、写入 runtime config、启动 loopback runtime、健康检查并执行 process identity claim。 |
| 输出 | status、logs、pid、runtime URL、identity status。 |
| 错误 | runtime 只监听 loopback；claim token 不写入 JSON config。 |
| 验证 | `npm run client:runtime:package`, `npm run client:native:test`。 |

## 功能项 CL-08 Activity And Snapshots

| 项 | 设计 |
| --- | --- |
| 目标 | 记录配置写入、Skill 变化、MCP apply/rollback、relay、runtime 和状态快照。 |
| 输入 | sidecar operation result、GUI action、state store update。 |
| 处理 | portable data 写入 activity 和 snapshot，GUI 渲染历史。 |
| 输出 | activity list、snapshot list、rollback target。 |
| 错误 | snapshot 不能包含 token 明文。 |
| 验证 | `npm run client:verify:state-store`。 |

## 功能项 CL-09 Settings

| 项 | 设计 |
| --- | --- |
| 目标 | 管理服务端地址、已知路径、手动目标、本机仓库位置、偏好和外观。 |
| 输入 | GUI settings、portable data、appearance preset。 |
| 处理 | Flutter 控制器更新 portable state；sidecar 使用同一数据目录。 |
| 输出 | settings JSON、UI state、theme preference。 |
| 错误 | GUI 不直接写服务端 runtime secret。 |
| 验证 | `npm run client:test`, `npm run client:verify:config-writes`。 |

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
| 验证 | `cargo test --manifest-path crates/lico-client-native/Cargo.toml`, `xcrun swiftc -parse-as-library apps/desktop/macos/MailHelper/LicoMailHelper.swift`, `npm run client:verify:architecture`。 |

## 功能项 CL-12 Secure Client Mesh

| 项 | 设计 |
| --- | --- |
| 目标 | 为 desktop GUI、desktop sidecar、mobile、CLI、client-local runtime、agent host 和 web_limited endpoint 提供统一 SecureEnvelope wire boundary。 |
| 输入 | `secure-mesh status`、`secure-mesh envelope validate`、`secure-mesh payload seal`、`secure-mesh payload open`、`secure-mesh command policy`、`secure-mesh command evaluate`、`secure-mesh command execute`、MobileRelayCompatibilityTransport delivery、GUI Secure Mesh status refresh、物理 Android 设备 proof JSON。 |
| 处理 | Native sidecar 校验 SecureEnvelope outer fields，提供原生 AEAD/HKDF payload seal/open binding，并让 pairwise session message key 或 MLS exporter-derived group content key 驱动 payload seal/open，执行本地 command allowlist / deny-prefix policy，并在命令 payload 解密后提供 schema、sender trust、target binding、risk、user confirmation、replay、idempotency、bounded SQLite ledger gate、本地 execution adapter 和 CLI runtime execution binding；同时提供 PC-PC/Mobile-PC/PC-Mobile/Mobile-Mobile/CLI-Desktop/client-local runtime command/result relay envelope 场景、multi-device encrypted fanout 独立 pairwise 密文副本与 ACK purge、typed encrypted result/error codec、encrypted file manifest/chunk codec 与 resume/ACK/purge state、device trust fingerprint/cross-signing/SAS/QR helper 与 policy evaluator、signed prekey/one-time prekey/KeyPackage signature-expiry-trust-low-water validator、Pactium-backed transparency verifier 目标、clean-room pairwise X3DH-ready/Double-Ratchet-style runtime、Sesame-style session manager、OpenMLS group add/update/remove/new-epoch wrapper、mls-rs independent Welcome join/application decrypt verifier evidence、group payload context binding 和 durable epoch metadata store/CAS/rollback/revoke tombstone，并把 Mobile Relay 默认能力限制为 `secure_mesh.envelope`。 |
| 输出 | protocol status、validated envelope metadata、sealed/opened payload metadata、本地 command policy/evaluation/execution result、desktop GUI Secure Mesh transport/readiness status、native Secure Mesh content/response/file/command/device-trust/prekey/transparency/MLS test evidence、JS/Rust sidecar wire parity evidence。 |
| 错误 | 没有已集成的 endpoint cryptographic runtime 或命令执行 adapter 时，不执行 relay envelope 内的命令 body，不把 SecureEnvelope 自动降级成明文命令。 |
| 验证 | `npm run client:verify:secure-mesh`, `npm run client:native:test`, `npm run client:test`。 |

当前状态：服务端 directory/delivery、客户端边界校验、JS/Rust sidecar wire parity、桌面 GUI Secure Mesh status、command execute polling、device-trust policy 与 default file route binding、Android Keystore MethodChannel runtime bridge、APK-bundled `lico-client-native` JNI native runtime self-test、物理 Android delivery-store-backed payload, endpoint signing, secure-store, runtime content-key binding, payload negative controls, Android-origin command/result proof, and app-process TLS-pinned LAN-direct probe、AEAD/HKDF payload codec、CLI payload seal/open binding、pairwise session-key payload codec、PC-PC/Mobile-PC/PC-Mobile/Mobile-Mobile/CLI-Desktop/client-local runtime command/result relay envelope 场景、server delivery store backed native command/result relay proof、multi-device encrypted fanout 独立 pairwise 密文副本与 ACK purge、MLS exporter-derived group payload codec、typed encrypted result/error codec、encrypted file manifest/chunk codec 与 resume/ACK/purge state、default encrypted file route evaluator、原生 no-plaintext canary 经 SecureEnvelope/file/Mobile Relay 路径投递验证、原生命令 schema/risk/replay/idempotency gate、bounded SQLite ledger、本地 execution adapter、CLI command execute runtime binding、device trust fingerprint/cross-signing/SAS/QR helper 与 policy evaluator、signed/one-time prekey 与 KeyPackage signature-expiry-trust-low-water validator、transparency inclusion/consistency/cached tree-head verifier、pairwise X3DH-ready/Double-Ratchet-style runtime、Sesame-style session manager、Cargo.lock exact-version/license allowlist、npm production audit、pinned RustSec advisory CI gate、物理 Android 设备互操作 verifier 与手动 CI 入口、OpenMLS 三端 add/update/remove/new-epoch wrapper、provider storage reload、secret-store file reload、CLI public MLS recovery vector、mls-rs 0.55.2 public-wire artifact parser、mls-rs 0.55.2 + mls-rs-crypto-openssl 0.21.0 独立 Welcome join/application decrypt runner、group payload context binding、removed-member group payload decrypt failure 和 durable epoch metadata store/CAS/rollback/revoke tombstone 已实现；production readiness 仍被 clean-room Signal-style pairwise audit、OpenMLS 完整跨实现恢复/解密互操作、reviewed/full Android Signal/OpenMLS protocol runtime integration、真实设备生产传输矩阵、Pactium-backed transparency migration、完整 QR/SAS/recovery/rotation/revoke UX、signed auto-update、explicit Windows ACL hardening 和 full release proof bundle 阻断。

客户端 verifier 还输出撤销端点门禁证据，证明被撤销 endpoint 不能继续通过 mailbox delivery、sync、ACK、file chunk、prekey 或 KeyPackage 路径参与后续互操作。

Android 物理机 verifier 现在可以显式 `--install --launch`，并在应用进程启动后读取 app-private 或 external app-specific `files/secure-mesh/android-runtime-status.json`。它要求 APK 中存在 `lib/arm64-v8a/liblico_client_native.so`，并要求 Android app 通过 JNI 加载该 Rust runtime 后完成 SecureEnvelope validation、command policy、payload crypto、pairwise runtime 和 MLS runtime status 自检，且不经 FFI 传递 secret。随后 verifier 会先在 Secure Mesh delivery store 中注册 macOS/Android endpoint，经 `cloud_relay` 向 Android mailbox 投递 macOS sidecar 生成的 encrypted challenge 和 pairwise/MLS runtime payload，sync 出 opaque envelope 后交给 Android app 打开；Android app 打开主 payload 后会在同一 app 进程内验证 wrong-context、ciphertext-tamper 和 wrong-payload-kind payload open 都被拒绝，再用 AndroidKeyStore P-256 端点签名 key 签署 endpoint challenge，用 AndroidKeyStore AES-GCM key 加密并重载 `pairwise_session` 与 `mls_group_epoch` secret-class probe；同时 Android 必须把 pairwise/MLS content key 写入 AndroidKeyStore-backed secure-store record，再用 reload 后的 content key 打开 server-delivered macOS runtime payload 并回封 Android runtime result。该 verifier 还让 Android 用 KeyStore-backed `physical_android_command` content key 封装只读 `client.activity.sync` command，经 delivery store 投递到 macOS mailbox；macOS sidecar 打开并执行本地 command gate 后，把 encrypted result 经 delivery store 投递回 Android mailbox，第二次启动 Android app 后打开该 server-delivered result。proof 不含明文 canary、raw secret 或 raw content key，macOS sidecar 会把主 Android encrypted result 经 delivery store 投递回 macOS mailbox、sync 后打开、ACK purge 两端 mailbox、扫描 persisted delivery store 无 canary，并验证 endpoint signing、secure-store、runtime-key-binding、native runtime self-test、payload negative controls 与 physical command/result evidence；同一 proof 还包含 Android app 进程 TLS-pinned transport probe transcript，当前通过 route 为 `lan_direct`，证明 Android app 进程经 WLAN 到达 macOS verifier listener，且不打开非 loopback cleartext HTTP；该证据不替代 reviewed/full Android Signal/OpenMLS protocol runtime integration 或 WebRTC 生产传输背书。
Retained local device-verification evidence is available at `build/reports/secure-mesh/device-verification-recovery/latest.json`. It ties the current Flutter relay panel, controller bindings, and native trust helpers together, but it does not claim a finished lost-device/reinstall/account-recovery flow or a physical-device E2E run.
