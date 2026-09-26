# 版本发布

Updated: 2026-09-25

[English](README.md)

发布状态以公开制品和验证收据为准；[包契约](../RELEASE-PACKAGES.zh-CN.md)
说明可用制品，[晋升门禁](PROMOTION-GATES.zh-CN.md)说明来源和制品边界。
本地进度与验收记录不在公开索引维护。

`npm run repo:version` 校验公开版本源保持一致、变更日志
包含该版本，并在要求校验标签时确认标签与版本一致。声明式版本源清单位于
`tools/release/source-version.json`。版本契约或校验器发生变更时运行
`npm run repo:version:test`。
