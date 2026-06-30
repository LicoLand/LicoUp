# LicoLite Desktop Client

LicoLite Desktop Client 是 LicoLite 本地客户端的 Flutter 桌面壳。客户端产品边界以
[`docs/functionality/CLIENT-DESKTOP.md`](../docs/functionality/CLIENT-DESKTOP.md) 为准。本仓库只
维护当前客户端版本，不保留并行旧版本实现。

## 产品范围

客户端现在定位为轻量本地环境管理器。它帮助用户查看和编辑目标原生 MCP 配置，
管理被动本地 Skill Hub，做薄模型转发，通过各智能体专属 adapter 精确导入原生
对话历史，并通过 activity 和 snapshot 恢复本地配置变更。

首批一等 target adapter 固定覆盖 Antigravity、Claude Code、Codex、Cursor、
GitHub Copilot、Hermes Agent、Kilo Code、OpenClaw 和 OpenCode。

默认 UI 只有七个一级模块：

- Agents
- MCP Plugins
- Skill Hub
- Model Forwarding
- Mobile Relay
- Activity And Snapshots
- Settings

客户端不拥有 agent harness、planner、tool loop、运行时审批系统、server API
console 或通用数据连接器运行时。

## 运行形态

- `apps/desktop` 提供 Flutter 桌面壳。
- `crates/lico-client-native` 提供 GUI 和目标智能体共同使用的本地命令面。
- Target adapter 读取或写入目标原生配置文件；目标有官方可脚本化 CLI 时优先
  调用官方 CLI。
- 本地状态使用可读 JSON、JSONL activity 记录和配置 snapshot，存放在客户端
  portable data root 下。
- LicoLite MCP 作为同级 MCP plugin 管理，不是有特权的 super-plugin。

默认打包由 [`apps/desktop/packaging.modules.json`](packaging.modules.json)
控制。唯一 package profile 是 `future-client`。

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

## 验证

主要客户端门禁：

```bash
npm run client:verify:architecture
npm run client:verify:plan
npm run client:verify:architecture
npm run client:verify
```

架构和计划 verifier 会守住单版本边界：默认导航必须保持七个模块，已移除的重
客户端模块不能重新进入构建，deferred 的 Skill Hub 协议工作不能被说成已完成。

## 打包

查看默认 package plan：

```bash
npm run client:package:plan
```

一键构建可运行 release 客户端：

```bash
npm run client:build:macos
npm run client:build:windows
npm run client:build:linux
npm run client:build:android
```

macOS 构建会自动从 Banner 提取的黑底 SVG
`apps/desktop/assets/brand/lico-app-icon.svg` 渲染 AppIcon PNG。需要只刷新图标时可单独运行
`npm run client:icon:macos`；不要用截图 PNG 作为长期图标源。

桌面客户端的直接运行入口会输出到
`build/apps/desktop/runnable/<platform>/<mode>/`。macOS 默认产物是：

```text
build/apps/desktop/runnable/macos/release/LicoClient.app
```

可直接双击 `.app` 或运行：

```bash
open build/apps/desktop/runnable/macos/release/LicoClient.app
```

需要让 macOS Applications、Spotlight 或 LaunchServices 能正常发现客户端时，使用
显式安装命令：

```bash
npm run client:install:macos
```

安装器会优先复用已安装的 `LicoLite Client.app` 位置；识别依据是 macOS bundle id
`com.lico.client`，会检查当前运行的客户端、`/Applications`、`~/Applications` 和
Spotlight 结果。
找不到已有安装时默认安装到 `/Applications/LicoLite Client.app`。需要强制用户级开发安装
时可设置 `LICO_CLIENT_INSTALL_DIR="$HOME/Applications"` 或传
`--install-dir "$HOME/Applications"`。安装时会按 bundle id 请求正在运行的 LicoLite Client
退出，再替换 app。

安装型 macOS `.app` 的运行数据默认写入系统 Application Support 下的
`portable-data` 子目录；不会使用构建目录或 `.app` 同级目录作为默认数据根。
`LICO_PORTABLE_DIR` 仅用于开发/测试中的 loose executable 或由 GUI 显式传给
sidecar 的已解析系统数据目录。

本机轻量 runtime 是客户端内的 Local Runtime 功能。GUI 不直接持有 process identity
私钥；Local Runtime 页面会调用打包进 `.app` 的 `lico-client` supervisor，使用客户端
自带 runtime package 启用、重建、刷新、重启、停止和查看日志。
底层 CLI 入口仍可用于排障：

```bash
lico-client local-runtime ensure \
  --port 17328
```

supervisor 会把内置 `client-local-runtime/source` 安装到客户端数据目录，生成
runtime instance config 和 `0600` claim token，启动 loopback runtime，完成健康检查
和 process identity claim；macOS 上私钥/能力密钥继续走 Keychain。之后可通过
`lico-client local-runtime status|logs|restart|stop` 查看和管理。

内部打包 bundle 仍保留在 `build/apps/desktop/bundles/<platform>/<mode>/bundle/`
用于审计和分发流水线。Android APK 会输出到 `build/apps/desktop/android/<mode>/`。
桌面打包会把 Flutter 工程复制到固定 clean build root 后构建，macOS 默认是
`/private/tmp/lico-client-build/source/apps/desktop`，Linux 默认是
`/tmp/lico-client-build/source/apps/desktop`；可通过 `LICO_CLIENT_CLEAN_BUILD_ROOT`
覆盖。脚本只把 `pubspec.lock` 锁定的 hosted packages 复制到该 root 下的
`pub-cache`，并使用 `flutter pub get --offline`，避免构建产物残留开发 checkout
或用户 Home 下的 pub cache 路径。默认会清理 staged Flutter 工程；需要保留
Flutter 构建缓存做本地调试时，可设置 `LICO_KEEP_FLUTTER_BUILD_CACHE=1`。

平台说明：

- Windows bundle 需要在 Windows 环境构建。
- Linux bundle 需要在 Linux 或 Ubuntu 环境构建。
- Android APK 需要本机 Flutter Android toolchain、Android SDK 和可用 NDK。
- macOS 主机可用 `npm run client:ubuntu:verify` 通过 Docker 执行 Ubuntu
  验证路径。
- 默认 package 只包含当前客户端模块和必要 native sidecar。
