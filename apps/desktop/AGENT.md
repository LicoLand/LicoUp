# Desktop Client Agent Entry

## Scope

- Owns the Flutter desktop client under `apps/desktop/`.
- Keep GUI changes inside `apps/desktop/` unless the task explicitly changes the
  Rust CLI, server API, packaging, or shared docs contract.

## First Reads

- Start with root `AGENT.md`, then this file.
- Read `apps/desktop/README.md` for local setup and product boundary.
- Inspect `apps/desktop/pubspec.yaml` before changing dependencies.
- Use `apps/desktop/lib/main.dart` and `apps/desktop/lib/app.dart` to enter the app
  tree, then open only the relevant feature files.

## Directory Routing

- `lib/`: Flutter application code.
- `test/`: widget, service, state, and contract tests.
- `scripts/`: packaging and client architecture verifiers.
- Platform folders (`macos/`, `windows/`, `linux/`) are only for native shell,
  packaging, or platform-specific behavior.

## Verification

- Use `npm run client:analyze` for Flutter static analysis.
- Use `npm run client:test` for Flutter tests.
- Use `npm run client:test:coverage` when LCOV output is needed; the report is
  written to `build/coverage/apps/desktop/lcov.info`.
- Use `npm run client:verify:architecture` when architecture rules or module
  boundaries change.

## Context Budget

- Do not load `build/apps/desktop/`, `apps/desktop/build/`, `.dart_tool/`, coverage
  output, or generated platform artifacts.
- Avoid reading CLI code unless the GUI task depends on a native CLI contract.
