# core/ — Shared Foundation Layer

Migration target for cross-feature shared infrastructure.
This layer contains NO business logic.

## Subdirectories

| Directory | Purpose | Migration Source |
|:---|:---|:---|
| `bridge/` | Flutter↔Rust typed bridge (flutter_rust_bridge v2 generated codecs) | `platform/native_client/`, `contracts/generated/` |
| `models/` | Generated immutable projections from Rust domain | `contracts/*_models.dart` |
| `errors/` | Typed error hierarchy matching Rust stable error codes | `contracts/problem_codes/` |
| `extensions/` | Dart extension utilities | scattered utilities |

## Rules

- No widget imports
- No feature-specific logic
- All types here are either generated or pure data
- bridge/ is the sole communication path to Rust
