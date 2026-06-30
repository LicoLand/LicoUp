# Lico-Arc

Lico-Arc is the private repository for the official LicoLite client product line:
Flutter desktop shell, native sidecar, client contracts, client scenarios, and
client release gates.

The public `LicoLite/LicoLite` repository owns the open gateway fabric,
protocols, SDK-facing contracts, self-hosted deployment path, and minimal
operator surfaces. Lico-Arc owns the proprietary product client experience.

## Repository Boundary

Private in this repository:

- Official desktop, mobile, and future client surfaces.
- Local product workspace UX, activity, snapshots, target adapters, Skill Hub,
  model forwarding, mobile relay, update channel, and client packaging.
- Native sidecar code used by the official client.
- Client product scenarios and release gates.

Public gateway-facing work stays in `LicoLite/LicoLite`:

- Gateway, relay, routing, policy hooks, audit, checkpoint, and receipts.
- Protocol specifications needed for third-party or self-hosted integration.
- SDKs, CLI/debug tools, and deployment examples that make the open gateway
  fabric usable without the official client.

## Local Setup

Required local tools:

- Node.js 22 or 24
- Flutter stable with desktop support
- Rust stable

Useful commands:

```bash
npm ci
npm run client:get
npm run client:analyze
npm run client:test
npm run client:runtime:package
npm run client:native:test
npm run client:verify
```

`npm run client:verify` is the local merge gate. It runs boundary hygiene,
client architecture/plan checks, schema checks, Flutter checks, and Rust sidecar
checks.

## Layout

| Path | Owner |
| --- | --- |
| `apps/desktop/` | Flutter official desktop client |
| `crates/lico-client-native/` | Native sidecar and `lico-client` command |
| `packages/contracts/client/` | Client DTO schemas |
| `packages/protocols/native-client/` | Client-side native protocol notes |
| `docs/functionality/CLIENT-DESKTOP.md` | Current client functionality contract |
| `docs/scenarios/personal-user/` | Client product scenario ledger |
| `tests/` | Client contract, native, release, and boundary checks |

## Contribution Boundary

Do not reintroduce a parallel legacy client, compatibility facade, or old
server-console product surface. Client refactors must complete the migration in
one pass: source, callers, docs, tests, packaging, and gates should all point to
the current client path before verification is treated as final.
