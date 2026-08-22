# Client-native interaction boundary

[Documentation](../README.md) · [Architecture](README.md)

Flutter reaches the Rust native host through the `licoup.stdio.v1` frame.
Stateful conversation operations use explicit methods with structured
parameters and results. They never use a CLI argument array as their
client-to-native transport.

The same frame still carries bounded stateless commands as `method: "execute"`
with an argument array. The native host parses that array through the public
CLI command model. Catalog and target queries are examples of this path.
One-shot execution exists only for injected executors and tests when the
persistent native host is unavailable; it is not the product transport for a
stateful turn.

Credential create and update requests rewrite private input onto stdin before
process launch. Secret values do not enter command-line arguments, reports, or
the public frame projection.

The implementation authorities are the native-client transport under
`apps/desktop/lib/src/platform/native_client/`, the client Agent services under
`apps/desktop/lib/src/backend/features/agents/services/`, and the native frame
router under `crates/licoup-native/src/bin/licoup/stdio_rpc/`.
