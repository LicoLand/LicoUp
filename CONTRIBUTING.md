# Contributing

Lico-Arc is the GPL-3.0-or-later open-source repository for the official LicoLite client product layer.
Encrypted communication is a native Lico-Arc capability and does not depend on a
relay or gateway server implementation; the custom encryption protocol authority
is in this repository. Open gateway fabric and non-encryption protocol work
belongs in `LicoLite/LicoLite` unless the change explicitly affects the official
client.

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
treated as ready. A retired product name is not a state-migration source:
initialize fresh current-name state and do not add discovery, import, rename,
copy, translation, prompts, fixtures, or compatibility gates for its data root
or preference namespace.
