# 发布包结构

[English（规范版本）](RELEASE-PACKAGES.md) · 简体中文（本地化） ·
[兼容性](COMPATIBILITY.zh-CN.md) · [运行手册](RUNBOOK.md)

Nightly 与 Stable 发布包保留同一个应用身份和数据根。签名更新清单使用 manifest-v2，
并绑定制品的发布轨道与状态迁移前沿。参见
[客户端更新与状态迁移](architecture/CLIENT-UPDATE-AND-STATE-MIGRATION.zh-CN.md)。

LicoUp 不存在“万能发布压缩包”。一次发布请求可以选择一个或多个精确发布
包目标；每个目标分别生成自己的原生安装包、渠道元数据、校验和与包级清单。

结构化权威是
[`tools/client-release-targets.json`](../tools/client-release-targets.json)。
`npm run client:support-matrix:sync` 会把当前支持状态投影到
[兼容性矩阵](COMPATIBILITY.zh-CN.md)。手工文档不得重复维护目标是否可发布。

目录中的每个条目都必须是精确元组，并声明以下字段：`platform`、
`distributionFamily`、`baseline`、`packageFormat`、`channel`、`arch`、
`updateAuthority` 和 `buildHost`。`platform` 表示操作系统表面，
`distributionFamily` 表示原生发行版或商店家族，`baseline` 表示最低兼容
基线，`buildHost` 表示该配方所属的构建主机。运行目标只是实现细节，不能
替代发布包目标。
v4 目录会拒绝目录、目标、产物、更新和构建器对象中的未声明字段，不会把旧
结构静默视为有效输入。

## 标准输出目录

```text
build/releases/<产品版本>/
├── macos-direct-arm64/
│   ├── LicoUp-macos-arm64.dmg
│   ├── LicoUp-macos-arm64.dmg.sha256
│   ├── LicoUp-macos-arm64-update.zip
│   ├── LicoUp-macos-arm64-update.zip.sha256
│   ├── LicoUp-macos-arm64.build.json
│   └── LicoUp-macos-direct-arm64.package.json
└── android-direct-arm64-v8a/
    ├── LicoUp-android-arm64.apk
    ├── LicoUp-android-arm64.apk.sha256
    ├── LicoUp-android-arm64.build.json
    └── LicoUp-android-direct-arm64-v8a.package.json
```

外层不再套统一压缩包。每个叶子目录都可以单独暂存和校验。包级清单绑定
发布目标、运行目标、平台、发行版家族、兼容基线、分发渠道、原生格式、架构、
产品版本、构建号、源码状态摘要、目标目录摘要、更新权威、所属构建主机、
文件大小和 SHA-256 摘要。通用 v4 平台构建清单还会重复证明发行版家族、基线、
更新权威和构建主机，并把每个已生成包产物与同一目标目录、运行目标、源码状态、
版本和构建号绑定。现有直发平台清单只能通过更严格的平台专用绑定进入暂存。

## 目标模型

发布包目标等于“平台 × 发行版家族 × 兼容基线 × 渠道 × 原生格式 × 架构”，
并另外绑定更新权威和所属构建主机。`linux-glibc-arm64` 之类的运行目标只
表示程序运行 ABI，不是可发布安装包。

| 目标家族 | 基线 | 原生格式 | 渠道 | 构建主机 | 更新权威 |
| --- | --- | --- | --- | --- | --- |
| macOS 直发（arm64） | macOS 11.0 | DMG | 仅本机 Developer ID 渠道 | macOS arm64 | 签名 HTTP 清单 |
| macOS App Store（arm64） | macOS 11.0 | PKG | App Store | macOS arm64 | App Store |
| Windows 直发（x64） | Windows 10.0.19041 | MSIX | direct | Windows x64 | AppInstaller |
| Windows Store（x64） | Windows 10.0.19041 | MSIX 上传包 | Microsoft Store | Windows x64 | Microsoft Store |
| Debian（arm64、x64） | Debian 12 | DEB | APT 仓库 | 对应 Linux 主机 | APT 仓库 |
| RPM（arm64、x64） | Fedora 39 RPM | RPM | RPM 仓库 | 对应 Linux 主机 | RPM 仓库 |
| Arch Linux（x64） | Arch Linux rolling | `.pkg.tar.zst` | Pacman 仓库 | Linux x64 | Pacman 仓库 |
| Arch Linux ARM（arm64） | Arch Linux ARM rolling | `.pkg.tar.zst` | Pacman 仓库 | Linux arm64 | Pacman 仓库 |
| Alpine（arm64、x64） | Alpine 3.20 | APK | Alpine 仓库 | 对应 Linux 主机 | Alpine 仓库 |
| AppImage（arm64、x64） | glibc 2.31 | AppImage | direct | 对应 Linux 主机 | AppImage 更新信息 |
| Android 直发（arm64-v8a） | Android API 21 | APK | direct | macOS arm64 发布主机 | 手工下载 |
| Android Play（arm64-v8a） | Android API 21 | AAB | Google Play | macOS arm64 发布主机 | Google Play |
| iOS App Store（arm64） | iOS 13.0 | IPA | App Store | macOS arm64 | App Store |

上表括号中的架构分别对应不同目标 ID。Debian、RPM、Arch Linux、Arch Linux
ARM、Alpine 与 AppImage 是有意分开的家族，不存在通用 Linux 发布包目标。

`packageBuildSupported` 与 `releaseSupported` 是相互独立的事实。某个配方
可以已经能够构建，但发布闭环仍被阻塞。macOS 直发目标明确禁止进入
通用或远程发布构建器，只允许在获得明确授权后使用本机 Developer ID 协调器。配方不可构建
时记录 `packageBlockers`；外部发布或回执不完整时记录 `releaseBlockers`。
这些稳定类型代码（例如 `apt_repository_publication_not_implemented` 或
`linux_native_package_receipt_pending`）不代表已经拥有凭据、仓库接受、签名、
公证或商店提交能力。

`tar.gz` 仍可把构建传入隔离验证机，但它只是内部证据载体，不得出现在发布
目标目录或公共 Release 资产中。

## 命令

只规划一个精确发布包：

```sh
npm run client:release:plan -- --target macos-direct-arm64
```

一次规划多个相互独立的包：

```sh
npm run client:release:plan -- \
  --targets macos-direct-arm64,android-direct-arm64-v8a
```

可以重复使用 `--target`，也可以使用逗号分隔的 `--targets`。重复目标、未知
目标、空字段以及环境变量和命令行同时指定目标都会被拒绝。`--all` 只用于
规划整个目录；构建时，如果任一目标没有适配当前宿主的已实现构建器，会在
产生部分结果之前失败。

构建、暂存和校验使用同一套单目标/多目标选择器：

```sh
npm run client:release:build -- --target android-direct-arm64-v8a
npm run client:release:stage -- \
  --target macos-direct-arm64 \
  --target android-direct-arm64-v8a
npm run client:release:verify -- \
  --targets macos-direct-arm64,android-direct-arm64-v8a
```

`stage` 只消费已经构建的原生产物并写入标准叶子目录。`verify` 会拒绝多余
文件、符号链接、陈旧包元数据、摘要不匹配和校验和不匹配。

`build` 会先执行目标的完整原生配方，再原子暂存整个所选集合。通用或远程
macOS 直发会直接失败；获得明确授权的本机操作方使用 Apple Release 所拥有的
`client:release:macos` 入口。该协调器强制 Developer ID、Hardened Runtime、
安全时间戳、公证、票据装订和 Gatekeeper 验收。Android 直发要求受保护
的 APK 签名输入。缺少平台权威时，会在替换任何标准包叶子前失败。

## 发布

GitHub 工作流接受同样的逗号分隔精确目标，但拒绝 macOS 直发目标；macOS
签名、公证、打包和发布保持仅限本机，并需要另行明确授权。prepare 阶段可以为所有
`packageBuildSupported` 为 true 的目标建立独立矩阵任务，并选择目标声明的
runner 标签。工作流会安装共享的 Node、Rust 与 Flutter 工具链；所属 runner
还必须提供该目标类型化预检所声明的原生打包工具和已授权构建凭据。prepare 只
构建、暂存、校验和上传包，不会提交到商店或软件仓库。publish 阶段只接受
`releaseSupported` 为 true
的目标，从同一个源码绑定的 prepare 运行下载所有包，校验完整目标目录和
每个安装包摘要，在同一 Draft Release 中完成合并，生成一份同时绑定每份包
清单摘要的跨目标消费者校验清单，并只在整个所选集合成功后发布一次。

商店和软件仓库提交仍是独立渠道操作。构建出 AAB、MSIX 上传包、DEB、RPM、
Pacman 包、Alpine 包或 App Store IPA，不代表对应商店或仓库已经接受。

原生格式模板位于
[`apps/desktop/packaging/`](../apps/desktop/packaging/)，外部规范链接由
[英文规范文档](RELEASE-PACKAGES.md#template-ownership)统一维护。

macOS 直发的完整边界见
[macOS 站外直发合规清单](platforms/MACOS-DIRECT-DISTRIBUTION.zh-CN.md)。
