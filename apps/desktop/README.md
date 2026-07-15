# Lico Arc Desktop Client

Lico Arc Desktop Client 是 LicoLite 本地客户端的 Flutter 桌面壳。客户端产品边界以
[`docs/functionality/CLIENT-DESKTOP.md`](../../docs/functionality/CLIENT-DESKTOP.md) 为准。本仓库只
维护当前客户端版本，不保留并行旧版本实现。

## 产品范围

客户端现在定位为轻量本地环境管理器。它帮助用户查看和编辑目标原生 MCP 配置，
管理被动本地 Skill Hub，通过各智能体专属 adapter 精确导入原生对话历史，通过
设置导出客户端日志，配置 Clash Proxy Bridge，并通过 snapshot 恢复本地配置变更。

当前打包 target projection 覆盖 Antigravity、Claude Code、Codex、Cursor、
Copilot、Hermes、Kilo Code、Kimi Code、OpenClaw、OpenCode 和 Pi。

默认 UI 只有六个一级模块：

- Agents
- MCP Plugins
- Skill Hub
- Mobile Relay
- Runtime
- Settings

客户端不拥有 agent harness、planner、tool loop、运行时审批系统、server API
console 或通用数据连接器运行时。

## 本机智能体对话等价边界

Agents 对话面的产品目标是：从 Lico Arc 转发对话与从原生智能体直接对话具有一致的可观察效果。两个方向都必须成立——原生创建后由 Arc 精确续接，以及 Arc 创建后由原生智能体精确续接——并保留真实 native session id、cwd、有效 model/reasoning/permission 设置、事件和工具顺序、最终结果、副作用、错误语义及原生历史回读。检测到二进制、导入历史或通过 synthetic driver 测试都不等于完成对话支持。

当前 reducer-owned readiness 是 `0 ready / 0 failed / 2 blocked / 9 unverified`，十一个打包 adapter 的发布 composer 均保持 fail closed。发布只声明实际 `ready` 的 adapter；其余状态不会启用发送，也不会单独阻塞客户端其它功能的打包。只有经当前 release `.app` GUI 连续通过三轮 paired run、每轮均覆盖两个方向，并完成边界、清理和隐私检查，reducer 才能把 adapter 提升为 `ready`。

连续的 reasoning、tool call/result、metadata、progress 和 error 事件在时间线中必须收敛成一个默认收起的过程卡片。激活后卡片保持可见并在原位置平铺展开多个脱敏操作，再次激活收起；不得点击即隐藏，也不得渲染为散落的多张技术卡片。原始思维链、工具参数、凭据、native id 和本机路径始终不可展示。

## 运行形态

- `apps/desktop` 提供 Flutter 桌面壳。
- `crates/lico-client-native` 提供 GUI 和目标智能体共同使用的本地命令面。
- Target adapter 读取或写入目标原生配置文件；目标有官方可脚本化 CLI 时优先
  调用官方 CLI。
- 本地状态使用可读 JSON、JSONL activity 记录和配置 snapshot，存放在客户端
  portable data root 下。
- LicoLite MCP 作为同级 MCP plugin 管理，不是有特权的 super-plugin。

默认打包由 [`apps/desktop/packaging.modules.json`](packaging.modules.json)
控制。唯一 package profile 是 `lico-client`。

## 本地开发

```bash
npm run client:get
npm run client:analyze
npm run client:test
npm run client:native:test
```

本地启动 Flutter 桌面端：

```bash
npm run client:run:macos
```

本地调试移动端：

```bash
npm run client:run:android -- --debug
npm run client:run:ios -- --debug
```

默认移动设备 id 使用 Flutter 的 `android` / `ios` 设备选择器；需要固定真机时设置
`LICO_CLIENT_ANDROID_DEVICE`、`LICO_CLIENT_IOS_DEVICE` 或直接在命令后传 `-- -d <device-id>`。

客户端 Flutter / Gradle toolchain 默认使用系统缓存目录下的 `LicoLite/client-toolchain`
隔离缓存，不把第三方包下载进源码树。可用以下环境变量覆盖：

```bash
LICO_CLIENT_CACHE_ROOT=/path/to/cache-root
LICO_CLIENT_PUB_CACHE=/path/to/pub-cache
LICO_CLIENT_GRADLE_USER_HOME=/path/to/gradle-user-home
LICO_CLIENT_ANDROID_PROJECT_CACHE=/path/to/android-project-cache
```

`npm run client:get` 会把 `pubspec.lock` 锁定的 Flutter 依赖拉到稳定 Pub cache；后续
`client:analyze`、`client:test`、`client:run:*` 和 Android APK 构建会先做离线锁文件
校验，并避免隐式 `pub get`。如果离线校验失败，先运行一次 `npm run client:get`。
Android run/build 首次使用隔离 Gradle cache 时会从已有系统 Gradle cache seed wrapper
distribution 和模块依赖；系统 cache 不存在时才需要 Gradle 自行联网下载一次。
`build/`、`.dart_tool/`、Android `.gradle/`、iOS `Flutter/Generated.xcconfig` 等生成物
只允许留在本地调试环境，必须保持不可提交。

## 验证

主要客户端门禁：

```bash
npm run client:verify:architecture
npm run client:verify:plan
npm run client:verify:agent-conversation-parity
npm run client:verify:secure-client-relay-mock-e2e
npm run client:test:android:native
npm run client:verify
```

`client:verify:secure-client-relay-mock-e2e` 只验证客户端固定的五个 POST 操作、六字段密文信封、重放/租约/ACK 语义和服务端可见线缆中无明文。公网网关可用性、服务端容量、存储、日志与服务端策略由服务端验收，不作为客户端发布门禁，也不通过导入服务端实现来验证。

Hosted CI structure is owned by [`docs/RUNBOOK.md`](../../docs/RUNBOOK.md). Keep this README focused on client-local commands and package outputs.

架构和计划 verifier 会守住单版本边界：默认导航必须保持六个模块，已移除的重
客户端模块不能重新进入构建，deferred 的 Skill Hub 协议工作不能被说成已完成。

## 打包

查看默认 package plan：

```bash
npm run client:package:plan
```

构建本地可运行客户端或平台包：

```bash
npm run client:build:macos
npm run client:build:windows
npm run client:build:linux
npm run client:build:android
```

上述 macOS 命令生成本地 ad-hoc runnable，不代表 Developer ID 分发包。生产分发入口和 Linux ARM64 归档入口分别是：

```bash
npm run client:build:macos:distribution
npm run client:archive:linux-arm64
```

这些 production 入口只用于对应平台或商店渠道：macOS 渠道可能要求 Developer ID、production entitlements 和 notarization，Linux 软件仓库渠道可能要求受保护的发布签名，Android 商店渠道可能要求受保护的 keystore。缺少相关输入时仅该渠道 fail closed，不阻塞源码开发、普通构建、客户端功能或 GitHub Release。Android PR/开发验证使用 `npm run client:build:android:debug`。开源仓库与 GitHub Release 只保留消费者校验官方分发包所需的最小摘要、签名/attestation 及公共验证材料，不公开发布账号、Team/Store 标识、稳定证书身份、凭据或私钥。

Platform package verifiers:

```bash
npm run client:verify:macos-local-bundle
npm run client:verify:macos-bundle
npm run client:verify:windows-bundle
npm run client:verify:android-apk
npm run client:linux:smoke
npm run client:linux:gui-smoke
```

平台发版选择与产品级全平台声明相互独立：

```bash
npm run client:verify:update-release
LICO_CLIENT_RELEASE_TARGETS=macos-arm64 npm run client:verify:github-release
```

只检查选定且目录明确支持 Release 的 target；unsupported target 不得出现在发布入口。GitHub Release 门禁仅绑定当前源码/版本、精确构建产物、规范 checksum，以及适用的 detached signature/公共验证材料。物理设备、平台安全存储、KT/MLS authority、独立密码审查和完整 Secure Mesh 证据由 `client:verify:product-line-security` 单独归约，不得阻塞或提升 GitHub 制品发布。平台生产签名、公证、商店/软件仓库上架、公开商店下载、更新和回滚仍只决定对应渠道状态。

macOS 构建会自动从 Banner 提取的黑底 SVG
`apps/desktop/assets/brand/lico-app-icon.svg` 渲染 AppIcon PNG。需要只刷新图标时可单独运行
`npm run client:icon:macos`；不要用截图 PNG 作为长期图标源。

桌面客户端的直接运行入口会输出到
`build/apps/desktop/runnable/<platform>/<mode>/`。macOS 默认产物是：

```text
build/apps/desktop/runnable/macos/release/Arc.app
```

默认启动必须走专用入口；它会构建标准 release runnable、关闭旧实例、校验
`lico-client` 侧车并只打开这一份客户端：

```bash
npm run client:run:macos
```

需要让 macOS Applications、Spotlight 或 LaunchServices 能正常发现客户端时，使用
显式安装命令：

```bash
npm run client:install:macos
```

安装器会优先复用已安装的 `Arc.app` 位置；识别依据是 macOS bundle id
`com.lico.client`，会检查当前运行的客户端、`/Applications`、`~/Applications` 和
Spotlight 结果。
找不到已有安装时默认安装到 `/Applications/Arc.app`。需要强制用户级开发安装
时可设置 `LICO_CLIENT_INSTALL_DIR="$HOME/Applications"` 或传
`--install-dir "$HOME/Applications"`。安装时会按 bundle id 请求正在运行的 Lico Arc
退出，再替换 app。

安装型 macOS `.app` 的运行数据默认写入系统 Application Support 下的
`portable-data` 子目录；不会使用构建目录或 `.app` 同级目录作为默认数据根。
客户端状态只使用其中的 `lico-client` 规范子目录。预发布状态根不受支持，
客户端不会探测、复制、重命名或导入这些状态；升级后会直接建立全新状态。
GUI 会把已解析的数据根通过 `LICO_CLIENT_PORTABLE_DIR` 显式传给 sidecar，确保
界面和 sidecar 读写同一份配置。`LICO_PORTABLE_DIR` 仅用于开发/测试中的 loose
executable。

本机轻量服务端是客户端内的 Local Runtime 功能。GUI 不直接持有 process identity
私钥；Local Runtime 页面会调用打包进 `.app` 的 `lico-client` supervisor，配置一次
源码仓库和 preset config 后即可在客户端内启用、重建、刷新、重启、停止和查看日志。
底层 CLI 入口仍可用于排障：

```bash
lico-client local-runtime ensure \
  --source-root /path/to/LicoLite \
  --preset-config /path/to/LicoLite/packages/foundation/config/composition-presets/client-local-runtime.preset.json \
  --port 17328
```

supervisor 会把 `client-local-runtime/source` 安装到客户端数据目录，生成
runtime instance config 和 `0600` claim token，启动 loopback 服务端，完成健康检查
和 process identity claim；macOS 上私钥/能力密钥继续走 Keychain。之后可通过
`lico-client local-runtime status|logs|restart|stop` 查看和管理。

内部打包 bundle 仍保留在 `build/apps/desktop/bundles/<platform>/<mode>/bundle/`
用于审计和分发流水线。Android APK 会输出到 `build/apps/desktop/android/<mode>/`。
桌面打包会把 Flutter 工程复制到系统临时目录内固定的
`lico-client-build/source/apps/desktop` clean build root 后构建；可通过
`LICO_CLIENT_CLEAN_BUILD_ROOT` 覆盖。脚本只把 `pubspec.lock` 锁定的 hosted packages 复制到该 root 下的
`pub-cache`，并使用 `flutter pub get --offline`，避免构建产物残留开发 checkout。
默认会清理 staged Flutter 工程；需要保留 Flutter 构建缓存做本地调试时，可设置
`LICO_KEEP_FLUTTER_BUILD_CACHE=1`。

## Clash Proxy Bridge

桌面设置页提供 Clash Proxy Bridge。它会检测本机 Clash Verge / Clash Verge Rev
常见配置中的 `mixed-port`，把 GUI 启动的 `lico-client` 调用注入
`HTTP_PROXY`、`HTTPS_PROXY`、`ALL_PROXY` 和 `NO_PROXY`，并为选中的智能体生成
客户端托管的 wrapper，例如 `lico-client/proxy-bridge/wrappers/lico-codex-proxy`。

CLI 入口：

```bash
lico-client proxy-bridge detect
lico-client proxy-bridge plan --targets codex,claude-code,antigravity
lico-client proxy-bridge apply --targets codex,claude-code,antigravity
lico-client proxy-bridge rollback
```

`apply` 只写客户端 portable state 和 wrapper 目录，不静默修改 Clash 配置或订阅。
TUN Assist 只生成可审查的 mihomo `tun`、`enable-process`、`find-process-mode` 和
`PROCESS-NAME` 规则片段；用户仍需要在 Clash Verge 内启用并授权 TUN。

Android APK 构建默认保留开发 checkout 下的 Flutter/Gradle 增量 build cache，避免
每次重新构建 Kotlin/Flutter 产物；需要强制清理时设置 `LICO_KEEP_FLUTTER_BUILD_CACHE=0`
或传 `--clean-flutter-build-cache`。默认 APK target platform 是 `android-arm64`，匹配当前
arm64-v8a native runtime；需要构建其他 ABI 时设置 `LICO_ANDROID_TARGET_PLATFORM` 或传
`--target-platform`。APK 输出仍只写入 `build/apps/desktop/android/<mode>/`。

平台说明：

- Windows bundle 需要在 Windows 环境构建。
- Linux bundle 需要在 Linux 或 Ubuntu 环境构建。
- Android APK 需要本机 Flutter Android toolchain、Android SDK 和可用 NDK。
- Platform verifier commands are listed above; hosted CI ownership and job matrix live in `docs/RUNBOOK.md`.
- 默认 package 只包含当前客户端模块和必要 native sidecar。
