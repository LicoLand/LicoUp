# LicoUp Native Client

This Rust crate owns the native CLI, local state and platform adapters, agent
drivers, Local Bridge transport, and Secure Client Mesh implementation used by
the Flutter client.

- Module map: [`src/lib.rs`](src/lib.rs)
- Public CLI: [`src/bin/licoup.rs`](src/bin/licoup.rs)
- Package definition: [`Cargo.toml`](Cargo.toml)
- Architecture: [`../../docs/architecture/README.md`](../../docs/architecture/README.md)
- Protocols: [`../../docs/protocols/README.md`](../../docs/protocols/README.md)

Run the maintained native verification from the repository root:

```bash
npm run client:native:test
```

Do not place runtime state, local paths, credentials, raw process output, or
device information in this module's fixtures or documentation.
