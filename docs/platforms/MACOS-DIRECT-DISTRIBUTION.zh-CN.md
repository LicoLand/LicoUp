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
4. 仅在应用验收后生成更新 ZIP；
5. 最终 DMG 完成签名、公证、装订、校验与 Gatekeeper 验收；
6. 隐私政策、Privacy Manifest、AGPL、项目 Notice 和第三方许可证均存在于应用资源中，
   且用户可在 DMG 根目录直接阅读相应材料；
7. 只有前序检查逐项通过后，才能推进摘要绑定的 Apple 会话；完成公开下载、安装与
   稳定启动验证后，才写入公开收据。

仓库 CI 工作流不得发布 macOS 直发产物。源码工作流直接从 `release` 创建该版本唯一的
`v<version>` Release；Apple Release 是唯一的 macOS 发布权威，只能在一次不可变
发布授权内驱动 Apple 与 GitHub 云端操作。它在 `macos-release-candidate` 上执行打包，
把五项 macOS 制品追加到同一个 Release，并且绝不替换源码资产。LicoUp 不实现第二套
macOS 发布器，也不再假定存在 Apple Release 后台服务。

## Apple Release 权威命令

先在独立的 `apple-release` 检出目录中执行 `npm install --global .` 安装私有 CLI。
仓库内配置只是声明式适配：Apple Release 拥有状态机、命令契约、签名、公证、GitHub
对账、公开发布、恢复语义和最终收据的控制权；LicoUp 只拥有
`tools/scripts/macos-release/` 中的产品适配层，按 Apple Release 规定的方式准备仓库
门禁、App 构建和签名更新清单。该目录的 `README.md` 给出完整脚本与制品清单。

签名密钥、公证凭据与 GitHub 身份验证仍留在各自安全存储中。公开输出不保留证书、
账户、供应商、凭据、原始输出或本机路径。

Agent 使用以下命令发起一次精确发布：

```sh
npm run client:release:macos -- --version <version> --build <build>
```

唯一一次授权提示之前只运行只读预检。接受后，Apple Release 独占精确接受的 release
来源、平台候选分支、发布门禁、Developer ID 打包、App 与 DMG 公证/装订/Gatekeeper 检查、精确
资产对账、公开发布、匿名公开下载、安装与稳定启动；不会再次提问。最终收据绑定
不可变 release 来源、追加到既有源码 Release 的安装包及其摘要、更新包及其摘要、
签名更新清单、Apple 结果与公开安装证明，共计五项 macOS 制品。

## Apple 一手资料

- [Developer ID 证书](https://developer.apple.com/help/account/certificates/create-developer-id-certificates)
- [macOS 软件公证](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution)
- [Hardened Runtime](https://developer.apple.com/documentation/xcode/configuring-the-hardened-runtime)
- [添加 Privacy Manifest](https://developer.apple.com/documentation/bundleresources/adding-a-privacy-manifest-to-your-app-or-third-party-sdk)
- [第三方 SDK 要求](https://developer.apple.com/support/third-party-SDK-requirements/)
- [防范可疑软件](https://developer.apple.com/support/protecting-users-from-suspicious-software/)
- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [Apple 开发者协议与规则](https://developer.apple.com/support/terms)
