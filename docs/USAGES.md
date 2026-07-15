# LicoLite Usages

## Metadata / 元数据

- Last updated: 2026-07-10
- Status: Current maintained document
- Scope: Script and command-line usage, separated into server and client.
- Staleness check: Checked against `package.json`, `tools/server-scripts/`, document governance verifier, `crates/lico-client-native/src/bin/lico-client.rs`, native-conversation driver/readiness resources, `crates/lico-client-native/src/core/secure_mesh.rs`, and `apps/desktop/scripts/` on 2026-07-10.

## 服务端

### 本机开发

```bash
npm install
npm run server:setup-runtime
npm run server:start:all
```

控制台默认地址是 `http://127.0.0.1:7228/`。

### Docker 本机启动

```bash
docker compose up -d
```

容器端口映射为 `7228:7228`，生产环境禁止直接裸露 HTTP 端口。

### 开发联调

```bash
npm run server:dev:all
```

开发模式同时运行后端 API 与 Vite HMR。`npm run server:dev:web` 只启动前端开发服务器。

### 生产监听

```bash
npm run server:start:public
```

该命令监听 `0.0.0.0:7228`。生产部署必须配置 HTTPS 反向代理、受控网段或隔离子网、运行态密钥管理、审计归档和备份恢复。

### 服务端常用脚本

| 命令 | 用途 |
| --- | --- |
| `npm run server:start` | 启动服务端。 |
| `npm run server:start:minimal` | 以 minimal profile 启动。 |
| `npm run server:start:client-local -- --runtime-config PATH` | 启动客户端本机 sidecar runtime，要求 explicit config。 |
| `npm run server:console` | 启动控制台服务。 |
| `npm run server:auth` | 管理控制台认证。 |
| `npm run server:auth:rotate` | 生成 owner 新密码。 |
| `npm run server:doctor` | 运行服务端诊断。 |
| `npm run server:locate` | 定位存储路径。 |
| `npm run server:reconcile` | 修复文件与 SQLite 元数据不一致。 |
| `npm run server:rebuild-metadata` | 重建元数据索引。 |
| `npm run server:runtime-downloads` | 启动 runtime dependency download 服务。 |
| `npm run server:mcp:doctor` / `npm run server:mcp:gateway:doctor` | 诊断 MCP 安装与发现。 |
| `npm run server:mcp:release` | 生成 MCP release 包。 |
| `npm run server:module:create` | 创建模块模板。 |
| `node tools/server-scripts/lico-module-contract-test.mjs` | 验证模块合同。 |

### 统一 CLI

```bash
npm run server:cli -- health
npm run server:cli -- settings get
npm run server:cli -- jobs list --limit 20
npm run server:cli -- search --query 合同
npm run server:cli -- rpc --method GET --path /api/healthz
npm run server:cli -- rpc-call jobs.list --params '{"limit":20}'
```

上传目录并等待结果：

```bash
npm run server:cli -- --path ./mail-folder --wait --output-result result.json
```

### 外部凭据初始化

真实 token 只能写入运行态 secret store。默认数据目录可用以下命令确认：

```bash
node tools/server-scripts/resolve-server-data-dir.mjs
```

Gerrit 示例：

```bash
printf '%s' "$LICO_GERRIT_HTTP_PASSWORD" | \
  npm run server:cli -- secret gerrit init \
    --base-url https://gerrit.example.com \
    --username svc-lico \
    --http-password-stdin \
    --mode live
```

外部知识蒸馏服务先跑门禁：

```bash
npm run server:verify:external-knowledge-distillation-service-gates
```

### 验证

| 场景 | 命令 |
| --- | --- |
| Required repository verification, including Secure Mesh all-gate and crypto dependency gates | `npm run verify` |
| 可提交功能门禁（确认上下游最小验证或客观阻断说明） | `npm run repo:commit-ready` |
| 文档/ADR 维护优先门禁 | `npm run server:verify:document-governance` |
| 文档治理 | `npm run server:verify:docs-governance` |
| 服务端核心回归 | `npm run server:verify` |
| Headless API | `npm run server:verify:headless` |
| 上传与 checkpoint | `npm run server:verify:checkpoints` |
| 存储运维 | `npm run server:verify:ops` |
| Operation Permission | `lico-dev workflow plan operation-permission` followed by the matching `lico-dev workflow run` command |
| ACP Relay | `node tools/server-scripts/verify-acp-agent-relay.mjs` |
| Secure Client Mesh control plane | `npm run server:verify:secure-mesh` |
| Secure Client Mesh JS/Rust wire parity | `npm run verify:secure-mesh:interop` |
| Secure Client Mesh physical Android endpoint evidence | `npm run verify:secure-mesh:android-device` |
| Secure Client Mesh property/fuzz harness | `npm run verify:secure-mesh:property` |
| Secure Client Mesh crypto dependency decision | `npm run verify:crypto-dependencies` |
| 外部服务注册 | `npm run server:verify:external-service-api-registration` |
| 状态机 | `npm run server:verify:state-machines` |
| 版本治理 | `node tools/server-scripts/verify-version-registry.mjs && node tools/server-scripts/verify-version-naming.mjs` |

`npm run verify:secure-mesh:android-device` 默认只读取当前设备、APK、安装状态、Android runtime status 文件和 proof JSON，不主动安装或启动应用。需要在已连接实机上执行安装/启动 harness、delivery-store-backed macOS-to-Android challenge relay、Android-to-macOS encrypted result relay、Android-origin encrypted command -> macOS native command gate -> encrypted result -> Android-opened result relay、ACK purge 和 no-canary persistence proof 时使用：

```bash
npm run verify:secure-mesh:android-device -- --install --launch
```

`npm run verify` 的 required profile 会执行 `node tools/server-scripts/verify-secure-mesh.mjs --gate=all` 和 `node tools/server-scripts/verify-crypto-dependencies.mjs`。物理 Android 互操作因依赖 self-hosted 实机环境，不作为普通 required profile 的本地步骤；它由手动 `android-secure-mesh-device-interop` CI job 构建 APK 并运行 `--install --launch` verifier。

## 客户端

### Flutter GUI

```bash
npm run client:get
npm run client:analyze
npm run client:test
npm run client:run:macos
```

### 客户端打包

```bash
npm run client:package:plan
npm run client:build:macos
npm run client:build:macos:distribution
npm run client:install:macos
npm run client:build:linux
npm run client:archive:linux-arm64
npm run client:build:windows
npm run client:build:android
```

macOS 构建产物：

```text
build/apps/desktop/runnable/macos/release/Arc.app
```

`npm run client:install:macos` 会优先复用已安装的 `Arc.app` 位置；识别依据是
macOS bundle id `com.lico.client`，会检查当前运行的客户端、`/Applications`、
`~/Applications` 和 Spotlight 结果。找不到已有安装时默认目标是
`/Applications/Arc.app`；需要强制用户级开发安装时设置
`LICO_CLIENT_INSTALL_DIR="$HOME/Applications"`。安装时会按 bundle id 请求正在运行的
Lico Arc 退出，再替换 app。

### Native sidecar 测试

```bash
npm run client:native:test
npm run client:verify
```

### `lico-client` 常用命令

当前打包 target projection 为 Antigravity、Claude Code、Codex、Cursor、Copilot、Hermes、Kilo Code、Kimi Code、OpenClaw、OpenCode 和 Pi Agent；命令参数使用对应 target id。该清单不代表 readiness。Kimi Code CLI 的 canonical target id 是 `kimi-code`；`kimi` 是独立的 Kimi Desktop/移动提供方身份，不能作为 CLI 转发驱动别名。Pi Agent 的 canonical target id 是 `pi`，官方车道为 `pi --mode rpc`（非 ACP / 非 HTTP serve）。

```bash
lico-client model profiles list
lico-client model profiles set local --command codex --args '["exec"]'
lico-client mcp config plan --target opencode --base-url http://127.0.0.1:7228
lico-client mcp config apply --target opencode --base-url http://127.0.0.1:7228 --token "$LICO_MCP_TOKEN"
lico-client mcp config rollback --target opencode --snapshot-id SNAPSHOT_ID
lico-client skill list --agent codex
lico-client skill get review-skill --agent codex --json
lico-client skill install plan --agent codex --url https://github.com/example/skills/tree/main/review-helper
lico-client skill install apply --agent codex --url https://github.com/example/skills/tree/main/review-helper --pin true
lico-client skill install rollback --agent codex --snapshot-id SKILL_INSTALL_SNAPSHOT_ID
lico-client conversations list --agent codex
lico-client agent-usage scan --agent codex --history-days 30 --timezone-offset-minutes 480 --timezone-transitions-json '[{"atEpochSeconds":0,"offsetMinutes":480}]' --force-refresh
lico-client agent-usage scan --agent codex --include-allowances
lico-client agent-usage report --agent codex --limit 10
lico-client mobile relay config get
lico-client secure-mesh status
lico-client secure-mesh envelope validate --envelope '{"protocolVersion":"licolite.secure-mesh.v1",...}'
lico-client secure-mesh command policy --command-kind agent.message.send
lico-client secure-mesh command evaluate --payload '{"schema":"licolite.secure-mesh.command.v1",...}' --context '{"localEndpointId":"pc-b",...}'
```

### 本机智能体对话等价验收

发布行为以 reducer 为准；当前 checked-in readiness 为 `0 ready / 0 failed / 2 blocked / 9 unverified`，且没有 `sendEnabled` adapter，因此十一个打包智能体的发布 composer 均保持 fail closed。驱动 inventory 仅将 Cursor 的供应商持久会话安全清理缺口和 Antigravity 的公开结构化 transport 缺口列为实现阻塞；Claude Code 的不持久化进程内续聊、Hermes 持久 ACP、Kimi Code canonical ACP 与 Pi exact RPC 已实现但仍为 `unverified`。发布只声明实际 `ready` 的 adapter；blocked、failed 与 unverified 条目保持禁用和可解释，但不单独阻塞客户端其它功能的打包。发现目标、读取历史、capability probe 或 synthetic self-test 都不能单独启用发送。

```bash
npm run client:verify:agent-conversation-parity
node tools/scripts/client-acp-conversation-parity.mjs --print-live-gate
node tools/scripts/client-acp-conversation-parity.mjs --agent "$TARGET_ID" --strict
npm run client:run:macos
node tools/scripts/client-acp-conversation-parity.mjs --agent "$TARGET_ID" --strict --release-ui
node tools/scripts/client-agent-conversation-parity-reducer.mjs --write
```

`--print-live-gate` 与无 `--release-ui` 的 `--strict` 只证明 harness / core lane 语义（`consecutivePasses` 保持 0）；不能单独启用发送。最终验收必须显式使用当前 release `.app` 内的 sidecar（`--release-ui`）并走真实 GUI。每个智能体必须连续通过三轮 paired UI run，每轮都覆盖两个方向：原生创建后由 Lico Arc 精确续接，以及 Lico Arc 创建后由原生智能体精确续接。验收比较真实 native session id、cwd、model/reasoning/permission 等有效设置、最终结果和副作用、事件/工具/错误顺序、推理安全投影、超时和边界、隔离清理及 argv/log/evidence 隐私。

GUI 中一段连续过程只能显示为一个默认收起的过程卡片。点击、触控或键盘激活后，卡片留在原位置并平铺展开多个有序操作；不得直接消失，也不得拆成 Metadata、Reasoning、exec、Tool result 等多张卡片。再次激活收起。展开内容只能包含脱敏详情和 provider 明确提供的 reasoning summary，不能显示原始思维链、工具参数、凭据、native id 或本机路径。

Mobile Relay production paths only carry `secure_mesh.envelope` SecureEnvelope commands sealed through pairwise sessions. Static content-key `payload seal`/`payload open` CLI routes and ACP plaintext protected-payload relay are not production paths; plaintext relay commands are rejected fail-closed.

### 客户端本机 runtime

服务端源码存在本机时，构建 client-local runtime：

```bash
npm run server:build:client-local
```

启动时必须传入 runtime config：

```bash
npm run server:start:client-local -- --runtime-config /path/to/client-local-runtime-instance.json
```

GUI supervisor 对应 sidecar 命令：

```bash
lico-client local-runtime ensure \
  --source-root /path/to/LicoLite \
  --preset-config /path/to/LicoLite/packages/foundation/config/composition-presets/client-local-runtime.preset.json \
  --port 17328

lico-client local-runtime status
lico-client local-runtime logs --tail 200
lico-client local-runtime restart
lico-client local-runtime stop
```

### 客户端验证

| 场景 | 命令 |
| --- | --- |
| GUI 静态检查 | `npm run client:analyze` |
| GUI 测试 | `npm run client:test` |
| Rust sidecar 测试 | `npm run client:native:test` |
| Secure Mesh client boundary | `npm run client:verify:secure-mesh` |
| 客户端架构门禁（含目标适配与 MCP 插件边界） | `npm run client:verify:architecture` |
| 本机智能体对话等价 reducer 与 synthetic ACP 门禁 | `npm run client:verify:agent-conversation-parity` |
| 全量客户端门禁 | `npm run client:verify` |
| 平台发布目标/子集合同 | `npm run client:verify:update-release` |
| GitHub Release 选定目标门禁 | `LICO_CLIENT_RELEASE_TARGETS=macos-arm64 npm run client:verify:github-release` |
| 产品线安全声明门禁（独立于 GitHub Release） | `LICO_CLIENT_RELEASE_TARGETS=macos-arm64 npm run client:verify:product-line-security` |
