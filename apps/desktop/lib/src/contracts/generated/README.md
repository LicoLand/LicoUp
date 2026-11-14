# Generated Contracts

Source of truth: `schemas/client_bridge/`.

Do not hand-write DTOs. All Dart-side contract types MUST be generated from the
JSON Schema files in `schemas/client_bridge/` via
`tools/scripts/generate-client-bridge-contracts.mjs`. If you need a new contract
type, add the schema there first and regenerate.
