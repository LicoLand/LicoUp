# Contributing

Lico-Arc is a private repository for the official LicoLite client product layer.
Open gateway fabric work belongs in `LicoLite/LicoLite` unless the change
explicitly affects the official client.

Before opening a PR:

```bash
npm ci
npm run client:get
npm run client:verify
```

Do not commit local paths, generated Flutter environment files, credentials,
tokens, runtime logs, private backend data, or product telemetry. Refactors must
complete the current-path migration in one pass: source, callers, docs, tests,
packaging, and gates should all point at the new path before the change is
treated as ready.
