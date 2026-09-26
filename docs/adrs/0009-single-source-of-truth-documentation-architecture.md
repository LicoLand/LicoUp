# ADR 0009: Documentation follows factual owners

Updated: 2026-09-25

[简体中文](0009-single-source-of-truth-documentation-architecture.zh-CN.md)

Status: Implemented

Repeated state tables, test assertions and progress claims drifted across documents.
The developer entry now routes to module guides. Each guide explains its necessary
trade-offs and links a stable verification command and test directory. Configuration,
registries and tests own executable facts; documentation owns design rationale.
Generated projections identify their source. No mandatory header template or second
prose specification is needed. The cost is maintaining the routing and generator
alongside the implementation. See the [developer guide](../RUNBOOK.md).
