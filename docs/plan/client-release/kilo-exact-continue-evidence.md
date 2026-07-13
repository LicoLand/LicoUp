# Kilo Code exact-continue evidence (redacted)

## Native-first finding (2026-07-13)

Kilo mirrors OpenCode’s serve/attach HTTP lane:

- `kilo serve --hostname 127.0.0.1 --port <n>`
- `kilo attach http://localhost:<n>` (vendor example documents `4096`)
- Health: `GET /global/health` → `{ healthy: true, version: <redacted> }`
- Exact session: `POST /session` returns `id`; `GET /session/{id}` returns the same `id`
- ACP (`kilo acp`) is a secondary vendor surface; Arc conversation send uses serve/attach
- Interactive `--continue` / `-c` is newest-session only and is not the Arc continue path

Arc owns ports **4097–4116** for auto-started Kilo serve (4096 reserved as vendor example; OpenCode’s 24173+ range reserved to avoid dual-serve collision).

## Implementation

| Item | Value |
| --- | --- |
| driverId | `kilo-code-serve` |
| runtimeProtocol | `kilo-code-serve-http-v1` |
| exactResume | declared `true` |
| streaming | declared `true` (SSE `/event` + final chunk emit) |
| sendEnabled | still `false` (fail-closed; no consecutive release-UI evidence) |

## Verification

- Unit: `cargo test … kilo_` — serve identity, empty-binary fail-closed, fake HTTP exact resume + chunk sink
- Live smoke (authorized host): `kilo serve` on 4097 proved health + create + exact GET
- Live product continue (list→send with stream-events) not yet recorded as consecutive release-UI passes

## Readiness impact

No readiness promotion. `sendEnabled` remains 0 until consecutive live release-UI evidence is reduced.
