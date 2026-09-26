# Deployment profiles, package closure and capability ownership

Updated: 2026-09-25

| Related Document | Language / Path | Authority |
|:---|:---|:---|
| **Normative Version** | English (Normative) | Authoritative contract for what is installed and what may be left out |
| **Extension contract** | [EXTENSION-PLATFORM.md](EXTENSION-PLATFORM.md) | Profiles, carrier, lifecycle and versioning |
| **Schemas** | [`schemas/extensions/deployment.schema.json`](../../schemas/extensions/deployment.schema.json) | Machine-readable form of the facts below |
| **Ownership and closure rules** | [`crates/licoup-extension-contracts/src/deployment.rs`](../../crates/licoup-extension-contracts/src/deployment.rs) | The closure algorithm, the ownership table and the refusals |
| **Security and data boundaries** | [SECURITY-AND-DATA-BOUNDARY.md](SECURITY-AND-DATA-BOUNDARY.md) | Trust, consent and data handling |
| **Documentation Index** | [docs/README.md](../README.md) | Complete documentation table of contents |

This document publishes what a distribution may contain, how the install closure
is computed from a package's own declarations, and which capability belongs to the
untouchable core versus a package a user may leave out. Per-platform delivery is a
separate question and is recorded in the platform matrix and release evidence.

## 1. One installation choice, not several products

A user selects a profile, or selects packages directly. Every selection uses the
same core, the same capability contracts and the same extension SDK. A profile is
a **recipe for an initial selection**, never a permanent prohibition: the user may
change profile or add, disable and remove packages at any time.

| Profile | Selected packages | Intent |
|:---|:---|:---|
| `minimal-local` | the core only | Local chat, stop, history and basic diagnostics, with an adapter the user supplies |
| `standard` | the core and a small set of preinstalled adapters | A default that runs out of the box |
| `gateway` | the core, a model gateway and compatible provider support | Routing across several providers |
| `peer` | the core, a general adapter and endpoint collaboration | Cross-device use |
| `workflow` | the core, a general adapter, multi-agent orchestration and outbound MCP | Local multi-agent development |
| `analytics` | the core, a general adapter and the statistics package | Extended usage and metric surfaces |

`minimal-local` is a complete product, not a crippled one. With no gateway, no
pairing, no orchestration and no advanced statistics, the client must still start
offline, chat, stop, show history and report basic diagnostics; the packages that
are absent must not be loaded, must not open listeners, must not require
migrations of schemas that do not exist and must not ask for keys or an online
catalog.

## 2. The core and its rule

The minimal trusted host carries four capabilities: the canonical conversation,
the extension host, the base usage journal and the declarative interface
primitives. These cannot be trimmed away, because removing them removes the
client.

**The core does not depend on anything removable.** An optional package may depend
on the core and on shared runtime; the reverse direction is refused by contract.
A core package that declares an install dependency on a trimmable package is a
build-time error in the closure, not a matter of review, because it is exactly the
shape by which a "small core" quietly becomes one large bundle.

Shared infrastructure — TLS, the database, the operating-system shim, the general
display primitives — stays in the core where it is genuinely needed, and is
counted in the core's real size. Logical module boundaries are not install
boundaries: one package may contain several cohesive modules, and one shared
runtime may serve several packages under explicit dependency and trust boundaries.

## 3. Per-capability ownership

Every capability has one owner: the core, or a specific package the user may leave
out. One capability may be *offered* by several packages — three adapters all
provide `agent-execution.v1` — and the table names the one the default
distribution provides.

| Capability | Owner | Set |
|:---|:---|:---|
| `conversation.v1` | `org.licoland.core` | Core |
| `extension-host.v1` | `org.licoland.core` | Core |
| `usage-journal.v1` | `org.licoland.core` | Core |
| `declarative-ui.v1` | `org.licoland.core` | Core |
| `agent-execution.v1` | `org.licoland.adapter.generic` | Optional |
| `model-provider.v1` | `org.licoland.provider.compat` | Optional |
| `model-gateway.v1` | `org.licoland.feature.gateway` | Optional |
| `analytics.v1` | `org.licoland.feature.analytics` | Optional |
| `endpoint-collaboration.v1` | `org.licoland.feature.collaboration` | Optional |
| `workflow.v1` | `org.licoland.feature.workflow` | Optional |
| `mcp-server.v1` | `org.licoland.feature.mcp` | Optional |
| `channel-connector.v1` | `org.licoland.feature.channels` | Optional |

The base usage journal is deliberately a small core slice that keeps the existing
ledger's ownership; advanced queries, policies and panels are optional and do not
copy the same data into a second store. A base metering fact is not deleted
because a panel was removed.

## 4. The install closure

A manifest declares two deployment relations, and they are not the same relation:

| Field | Meaning |
|:---|:---|
| `requires` | Installed together with this package. This is the install closure |
| `optionalRequires` | Enabled when the user already has it. Never installed on this package's account, and never a reason to refuse the package |

The closure follows `requires` only. An unknown package — a root that is not
present, or a required dependency that is not — refuses the plan with the
dependent package named, because "this package needs something you do not have" is
a fact the user can act on. A cycle among `requires` entries is refused outright:
there is no order in which such a set can be installed. Optional dependencies that
were declined are reported, so the user can decide rather than have the decision
made silently.

These relations are **deployment** relations. They decide which packages are
installed together and nothing about the development task graph that produced
them; package ranges are recorded rather than solved, and constraint resolution,
artifact selection and the install journal belong to the host's package manager.

## 5. Permissions

A manifest asks, and the host grants. There is no field in which a package can
record that it has been granted something, a directory listing is not an
authorization, and installing from a directory does not widen a scope.

- A first install, a widened scope and a new network domain each need the user's
  agreement or an existing explicit policy.
- Post-install scripts are not executed by default. A descriptor's command is a
  start target the user authorized, not an installer.
- Signatures and content hashes are produced from the bytes by packaging and by
  the update mechanism. A manifest that claims it has already been verified is
  refused.
- Signing in may unlock a directory. It is never required: importing a package the
  user already has is a first-class path, and binding trust to specific content is
  enough for a self-made one.
- A permission already granted does not automatically follow a changed credential
  domain, and removing the related package does not silently restore an old
  default.

## 6. Four facts, never one

Available, installed, enabled and active are four independent facts, and there is
no single "ready" that merges them. The interesting states are the mixed ones.

| Fact | Meaning |
|:---|:---|
| Available | Present in a directory. A local import was never in a directory, so being installed does not imply this |
| Installed | On disk, under a versioned, content-addressed location that never overwrites a file in use |
| Enabled | Installed and not disabled by the user. Enabled is not started: activation stays lazy |
| Active | An instance of this package is running |

A package's own lifecycle runs from available through downloaded, verified or
locally approved, staged and installed. A publisher signature that was checked
against a trusted update mechanism and a user's trust bound to specific content
are two different facts, and neither is more installed than the other. Instance
lifecycle — discovered, preparing, active, draining, stopped, failed, quarantined
— is separate again, because one package version may produce several instances
with different permissions.

Removing a package withdraws new admission, lets existing instances drain while
the user may also cancel what remains, revokes the contribution and credential
abilities, stops the process and then removes code with no remaining reference.
History, credentials and protocol state are separate, explicitly requested
operations. A runtime the user installed is never removed, a shared runtime is
removed only when no package references it, and space that is still occupied by a
pinned old generation is not reported as freed.

## 7. An unavailable capability is a catalogue fact

A capability that is not served is reported where capabilities are listed, with a
state — served, installed but not enabled, not installed, not in this
distribution — and not as an error banner. An operation that needs it is refused
as an unavailable capability whose recovery points at installing or enabling the
package that carries it, never as a malformed request and never as a reason the
client failed.

Not installing a package is a legitimate configuration, and the client must be
able to say so. A missing optional runtime is a fact about this installation.

## 8. Not claimed here

This document does not state that any listed package has been built, signed,
published or measured. Package identifiers describe the default distribution's
intent; artifact inventories, link closures, digest material, download and
expanded sizes, and per-platform delivery rules are separate, measured facts
recorded in release evidence.
