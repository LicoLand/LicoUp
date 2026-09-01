# macOS 站外直发合规清单

[English](MACOS-DIRECT-DISTRIBUTION.md)

本文只适用于 Mac App Store 之外的 Developer ID 直发。只有最终产物真实通过
签名、公证、票据装订和 Gatekeeper 验收后，仓库才允许声明“发行就绪”。当前
Mac App Store 目标仍受沙盒、进程模型、自更新权威和提交流程阻塞，不能与直发
渠道混为一谈。

## Apple 要求与仓库控制

| 要求 | 仓库控制 | 当前状态 |
| --- | --- | --- |
| 站外分发的 `.app` 使用 `Developer ID Application` | 本机平台渠道协调器在打包前校验证书类型、团队、应用标识符和 Profile 授权 | 已实现；真实发行证据待执行 |
| 所有可执行代码签名，启用 Hardened Runtime，带安全时间戳，并禁止 `get-task-allow` | 先清点并签名嵌套代码，再签外层应用；签名后逐项校验 Developer ID、Runtime、时间戳、权限和嵌套闭包 | 已实现；真实发行证据待执行 |
| Developer ID 软件提交 Apple 公证并装订票据 | 应用与最终 DMG 均通过 `notarytool` 提交、`stapler` 装订与复验，并用 `spctl` 验收；失败时不生成就绪清单 | 已实现；真实发行证据待执行 |
| macOS 只申请实际需要的敏感资源，并且只在当前操作需要时申请 | macOS 目标不含摄像头用途说明。自动发现只探测 Agent 扫描路径清单，启动时不执行第三方 Agent 二进制，家目录只从环境变量读取（含 firmlink 等价路径），并对个人资料库根、照片/音乐库、网络宗卷、iCloud 容器和其他 App 容器做词法分类，不去 `stat`。Token 用量在打开监测页之前不会扫描。进入某个 Agent 的对话界面后仍可读取该 Agent 自己的存储 | 已实现 |
| 准确披露隐私实践和第三方 SDK 行为 | `PrivacyInfo.xcprivacy` 与中英双语隐私政策只进入 macOS 应用/DMG 发行路径；当前声明无跟踪、无项目方运营的数据收集，并披露有代码证据的文件时间戳、系统启动时间与 User Defaults Required Reason API 用途 | 已实现；依赖或数据流变化时必须重审 |
| 防止自更新被替换或降级为其他签名者 | 更新候选必须匹配当前应用的准确 Developer ID designated requirement 与团队，并通过签名、Runtime、时间戳、公证票据和 Gatekeeper；替换脚本会再次复验 | 已实现；真实更新证据待执行 |
| 对发行代码和依赖负责 | LicoUp 不再下载、安装、更新、回滚或跨设备同步技能；只发现本机已有技能，并可把选中目录移入系统废纸篓。发行包附带 AGPL、项目 Notice、Flutter/Dart notices，以及从锁定 Rust 依赖图按目标筛选生成的依赖清单和可用许可证文本 | 技能与随包材料已实现 |
| 密钥不得进入源码或远程发布任务 | 签名与公证输入仅允许本机使用；仓库门禁和 Rulesets 拒绝证书/密钥类文件；旧 GitHub/本地临时身份 macOS 归档与安装入口已停用 | 已实现 |

## 直发与 Mac App Store 的区别

Apple《App Review Guidelines》2.5.2 对 App Store 应用下载、安装或执行会改变
功能的代码有明确限制；它不是 Developer ID 直发规则的替代品。LicoUp 仍然主动
移除了技能交付能力，同时不把当前的外部进程、自更新或可选适配器模型描述为
Mac App Store 兼容。

用户另外取得的第三方适配器或协作组件仍属于第三方软件，不会因为 LicoUp 主应用
已公证就自动获得信任。官方 LicoUp 发行包中随附或由官方渠道分发的代码仍由发行方
负责；用户自行放入本机智能体目录的技能由用户与其来源方负责。

## 发行验收边界

脚本存在、证书存在都不等于发行合格。最终且未被再次修改的同一份产物必须在一次
本机发行运行中满足：

1. 元数据、隐私清单、entitlements、证书、Profile 与工具链预检通过；
2. 所有嵌套可执行代码和外层应用均具备 Developer ID、Hardened Runtime 与安全时间戳；
3. 应用完成公证、票据装订并通过 Gatekeeper；
4. 仅在应用验收后生成更新 ZIP；随后由配置的 update 命令生成并签名更新清单，
   成为第五个发行资产；
5. 最终 DMG 完成签名、公证、装订、校验与 Gatekeeper 验收；
6. 隐私政策、Privacy Manifest、AGPL、项目 Notice 和第三方许可证均存在于应用资源中，
   且用户可在 DMG 根目录直接阅读相应材料；
7. 只有前序检查逐项通过后，才能推进摘要绑定的 Apple 会话；完成公开下载、安装与
   稳定启动验证后，才写入公开收据。

远程工作流不得发布 macOS 直发产物。本机 Apple Release 引擎只能执行单次不可变发布
授权中逐项列明的上传与公开变更。

## 本机授权

先在独立的 `apple-release` 检出目录中执行 `npm install --global .` 安装私有 CLI，
再在发布工作站上配置一次发布授权：

```sh
npm run client:release:authority:configure
```

配置过程选择 Developer ID Provisioning Profile，并填写现有签名身份与 `notarytool`
钥匙串 Profile 的名称。CLI 把 Profile 副本保存在权限受限的权威目录；签名密钥、
公证凭据与 GitHub 身份验证仍留在各自安全存储中。公开输出不保留证书、账户、供应商、
凭据、原始输出或本机路径。

更新清单签名增加一条授权前置条件：配置前先把两把 Ed25519 PEM 私钥导出到环境
变量，CLI 会把它们登记进 Keychain，随后可取消导出：

```sh
export LICO_UPDATE_OFFLINE_ROOT_KEY=<offline-root-ed25519-pem>
export LICO_UPDATE_ONLINE_CHANNEL_KEY=<online-channel-ed25519-pem>
npm run client:release:authority:configure
unset LICO_UPDATE_OFFLINE_ROOT_KEY LICO_UPDATE_ONLINE_CHANNEL_KEY
```

缺少任意一把密钥的发布运行会在预检阶段被拦截。

Agent 使用一条命令发起一次精确发布：

```sh
npm run client:release:macos:publish
```

该命令从冻结 `release` 修订的版本文档推导版本号与构建号，一次授权后跟随发布
直到终态收据。`npm run client:release:macos` 仍是交互变体。

唯一一次授权提示之前只运行只读预检。接受后，CLI 拉起 detached runner 独占精确接受的
release 来源、发布门禁、Developer ID 打包、App 与 DMG 公证/装订/Gatekeeper 检查、精确资产对账、公开发布、匿名公开下载、
安装与稳定启动；不会再次提问。最终收据绑定不可变 release 来源、五个公开制品
摘要、Apple 结果与公开安装证明。签名更新清单随其余资产一并上传，并通过同样的
匿名公开下载核验。

## Apple 一手资料

- [Developer ID 证书](https://developer.apple.com/help/account/certificates/create-developer-id-certificates)
- [macOS 软件公证](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Hardened Runtime](https://developer.apple.com/documentation/xcode/configuring-the-hardened-runtime)
- [添加 Privacy Manifest](https://developer.apple.com/documentation/bundleresources/adding-a-privacy-manifest-to-your-app-or-third-party-sdk)
- [第三方 SDK 要求](https://developer.apple.com/support/third-party-SDK-requirements/)
- [防范可疑软件](https://developer.apple.com/support/protecting-users-from-suspicious-software/)
- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [Apple 开发者协议与规则](https://developer.apple.com/support/terms)
