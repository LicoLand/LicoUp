# Extension platform and SDK contract

Updated: 2026-09-25

| Related Document | Language / Path | Authority |
|:---|:---|:---|
| **Normative Version** | English (Normative) | Authoritative contract for the extension platform |
| **Deployment and ownership** | [DEPLOYMENT-PROFILES.md](DEPLOYMENT-PROFILES.md) | Profiles, install closure, permissions, per-capability ownership |
| **Schemas** | [`schemas/extensions/`](../../schemas/extensions) | Machine-readable form of every shape below |
| **Contract crate** | [`crates/licoup-extension-contracts/`](../../crates/licoup-extension-contracts) | The rules, catalogs and refusals in executable form |
| **Agent adapters** | [AGENT-ADAPTERS-ARCHITECTURE.md](AGENT-ADAPTERS-ARCHITECTURE.md) | Current adapter and runtime layering |
| **Security and data boundaries** | [SECURITY-AND-DATA-BOUNDARY.md](SECURITY-AND-DATA-BOUNDARY.md) | Trust, isolation and data-handling rules |
| **Documentation Index** | [docs/README.md](../README.md) | Complete documentation table of contents |

This document publishes the contract an extension is written against. It is a
contract, not a claim about a shipped feature set: which parts the running client
already enforces is recorded in [STATUS.md](../STATUS.md) and in release evidence,
never inferred from this page.

## 1. What an extension is

An extension is a **separate program**. The client starts it, speaks one
line-delimited JSON-RPC 2.0 protocol to it, and renders its results. It is not a
Dart widget injected into the shipped client, not a dynamically loaded library in
the client's address space, and not a second copy of the client's internal
objects.

The consequence that matters for authors is that the contract is
**language-agnostic**. A Rust, Go, Python, Node or shell program that reads one
JSON object per line and writes one JSON object per line is a complete extension.
No SDK runtime is required, and no client internals are exposed: an extension
never sees the conversation domain, the workflow engine or the client's state
root.

Three properties are guaranteed by construction rather than by convention:

- **Local import is first-class.** A package a user built, a directory on this
  machine, an official directory and a third-party mirror are all just sources.
  Installing a local package skips the network entirely, and no part of this
  contract requires a registry, a directory service or an account.
- **Absence is a catalogue fact.** A capability whose package is not installed is
  reported as an unavailable capability with a stated next step. It is never a
  malformed request and never a reason the rest of the client fails.
- **Nothing is bundled for a vendor.** The minimal core carries the extension
  host and the general display primitives, not a directory of vendor
  implementations. See [DEPLOYMENT-PROFILES.md](DEPLOYMENT-PROFILES.md).

## 2. The five profiles

A package declares which of five **narrow** profiles it serves. There is no
universal `call` interface: a universal interface would make every extension
responsible for every host feature and would make "this pack does not do models"
indistinguishable from "this pack is broken".

| Id | Contract | Required methods | Optional methods | What holds one profile |
|:---|:---|:---|:---|:---|
| `agent-execution` | C09 | `extension.initialize`, `extension.ready`, `extension.shutdown`, `agent.describe`, `agent.execute`, `agent.event` | `agent.cancel`, `agent.observe`, `agent.resume`, `agent.steer`, `agent.fork`, `agent.reconcile`, `agent.history`, `agent.models` | Local import and process carriage |
| `model-provider` | C10 | `extension.initialize`, `extension.ready`, `extension.shutdown`, `modelProvider.describe`, `modelProvider.stream` | `modelProvider.models`, `modelProvider.cancel`, `modelProvider.reconcile`, `auth.begin`, `auth.continue`, `auth.refresh`, `auth.revoke` | User-supplied configuration or a provider package |
| `usage-metric` | C11 | the handshake, and at least one of `usage.publish` or `usage.query` | `usage.describe` | The core usage journal, or an optional source package |
| `package-deployment` | C12 | none | none | Declarations and package facts; no call is made |
| `declarative-ui` | C13 | none | none | A resource other profiles' packages contribute |

A profile decision is **local**. An extension that declares a profile this host
does not publish keeps working — the declaration is preserved and never acted on.
An extension whose `agent-execution` major is 2 is refused for Agent work and for
nothing else. An extension that implements `agent.describe` and `agent.execute`
but not `agent.event` is refused for Agent work with a refusal that names the
missing method. The same extension's other profiles are unaffected, and so is the
rest of the client.

The smallest useful Agent implements exactly the six `agent-execution` methods and
is complete. It needs no model, no tool call, no session resume, no usage
reporting and no remote idempotency, and none of those absences is a defect.

## 3. The carrier

The baseline carrier is a child process: one frame per line, `stdout` carrying the
program protocol and nothing else, diagnostics on `stderr` and bounded. A local
IPC channel and an already-connected service are the other two carriers; they
speak the same profile, so an extension does not become a different kind of
program by moving from a pipe to a socket. A connected service is bridged rather
than started, and reports its own cancellation and recovery abilities.

| Bound | Value | Why it exists |
|:---|:---|:---|
| Initial frame bound | 64 KiB, negotiated to the smaller of the two sides | A frame bound that only one side sets is a memory ceiling the other can raise |
| Accepted range | 4 KiB to 8 MiB | Below the floor, ordinary descriptions do not fit; above the ceiling, "negotiable" is an unbounded buffer |
| Diagnostic line | bounded | A chatty adapter must not be able to stop the client from responding |
| Reserved control slots | 4 frames | A cancellation may not queue behind a large data frame |

Oversize payloads are **chunked** or replaced by a **controlled blob handle** the
host issued. A handle is an opaque token, never a filesystem path: accepting a
path would turn "here is a large file" into an instruction for the host to read a
file the extension chose.

On a carrier that supports only one stream, the honest statement about
cancellation is a **worst-case wait** — the negotiated frame bound times the
reserved slots — not a claim that an unsplittable write can be preempted in the
middle. Cancellation is a request: once an effect has left the machine, the client
can stop waiting and stop local work, and it cannot claim the remote effect was
withdrawn.

## 4. Lifecycle and identity

The handshake is three methods and no business call:

1. `extension.initialize` negotiates the host protocol and the profile set.
2. `extension.ready` publishes the fact that the extension is prepared.
3. `extension.shutdown` asks for an ordered exit.

An extension with no ordinary business call is never started. Declaring a profile
costs nothing until something needs it.

Instance binding is established **once** per stream, not repeated per event:

```
extensionId / packageDigest / packageVersion / instanceId / generation /
registryEpoch / profileVersion / configRevision / authorityRef
```

A content event therefore carries only its invocation reference, a monotone
sequence and its own kind; the cursor and the identity come from the binding. The
permission handle in that list is assembled by the host and cannot be supplied by
input with the same name.

Package state and instance state are different facts and are never collapsed into
one version token. A package version may produce several instances with different
permissions, and `packageVersion`, `instanceId`, `generation` and the registry
epoch are four separate identities.

## 5. Agent execution

| Method or event | Requirement | Meaning |
|:---|:---|:---|
| `agent.describe` | required | Instance kind, input kinds, capabilities, interface version. Answerable from the package manifest, and it performs no paid inference |
| `agent.execute` | required | Submits an admission the host has already accepted, and returns a receipt that is not a completion |
| `agent.event` | required | `text`, `artifact`, `progress`, `state`, `terminal`. The SDK owns the envelope; the body is carried verbatim |
| `agent.cancel` | optional | `requested`, `acknowledged`, `unsupported` and `unknown` are four separately visible outcomes |
| `agent.observe`, `agent.resume` | optional | Address a specific prior invocation and cursor. Re-sending the same task is not a resume |
| `agent.steer`, `agent.fork` | optional | Only where the native capability exists; a native session is not a Conversation identity |
| `agent.reconcile` | optional | Queries a prior effect identity; when it is unsupported the result stays Unknown |
| `agent.history`, `agent.models` | optional | Paginated read-only history and catalog; they never block ordinary execution |

Two rules keep the client from telling a comfortable story:

- **Admission is not completion.** The receipt of `agent.execute` reports that the
  work was taken, that it was already taken, that it was never started, or that
  the outcome was not observed. A terminal *event* is the only thing that reports
  an end, and it is a different fact from "the call came back".
- **A dropped connection is an unknown effect, not a retry.** With no remote
  idempotency, a submission that was sent and never answered may or may not have
  started something. Only an extension that reports *not started* is a basis for
  submitting the same invocation again; everything else is reconciled against the
  durable record. An equal outer request id proves nothing about the remote
  service.

An ordinary CLI can be carried by the general adapter, which converts its output
into text and terminal events. A user does not have to modify an Agent to emit
client JSON, and text that merely *looks* like an envelope is still text.

## 6. Model providers

A provider owns a model protocol, its authentication, its model catalog and its
stream. Gateway functionality is one consumer of providers, and it is not a
prerequisite for defining one: a user who already has a local endpoint never has
to install a gateway to reach it, and removing a gateway does not remove a
provider another consumer still uses.

Configuration carries `id`, `displayName`, `baseUrl`, `apiDialect`,
`credentialRef`, `configRevision`, `catalogSource`, models and versioned
compatibility options. No endpoint and no model id is pre-listed, and the
compatibility parameters are separate from key material.

| Rule | Statement |
|:---|:---|
| Unknown stays unknown | A model whose vendor publishes no context limit, tool support or reasoning options reports nothing. No default window, no implied `false` |
| Keys are handles | The configuration carries a `credential:` handle. Key material pasted inline is refused before the configuration is stored, logged or graphed |
| Scope is per endpoint | A handle issued for one provider and origin is not resolved for another. Pointing a provider at a new base URL does not inherit the old endpoint's secret |
| Custom APIs are custom | A dialect that is not a published compatible one owes its own stream adapter rather than imitating a compatible API |
| Catalog keys are tuples | `(providerId, providerGeneration, vendorModelId)`. A human alias is a separate mapping, and only an explicit replacement changes future selection |

A price table is estimate material and is not an incurred cost. Cost is an
observation under C11, an unknown cost is reported as unknown rather than as zero,
and one provider's removal neither rewrites another provider's configuration nor
restores an arbitrary earlier default.

## 7. Usage and metrics

A usage source produces **observations**, not charges. The host decides what an
observation means for budget and settlement.

| Field | Meaning |
|:---|:---|
| `observationId`, `revision`, `operation` | Stable identity within one source epoch; a correction raises the revision; `retract` withdraws that observation and nothing else |
| `sourceEpoch` | Reset and replay defence. A new epoch starts new cumulative series |
| `scopeRef` | An invocation or an authorized aggregate read range issued by the host |
| `observedAt`, `intervalStart` | UTC as observed, and the window or series origin. An anomalous clock is preserved as the source's own fact and never overrides the host's monotonic clock |
| `metrics` | Namespaced metric to reading with `value`, `unit`, `temporality`, `quality` and included subsets |

The **source** is bound by the transport and is never self-declared. An
observation carries no `extensionId`, no `instanceId` and no principal, and a
payload that asserts one is refused, so no producer can attach itself to another
user's run.

Money is an exact decimal string with an ISO 4217 code; binary floating point does
not enter a ledger. A cumulative counter is differenced only within one epoch, one
metric and one origin, and a regressed counter means a reset and a new origin
rather than a negative amount of work. A value the producer does not know is
`unknown` with no number at all, because a zero would be a claim that nothing
happened. A producer reporting `reported` gains no settlement authority from
saying so.

Sources push through `usage.publish` or are pulled through
`usage.query(cursor, limit, scopeRef)`; `usage.describe` declares the fields and
series they offer. Log and OpenTelemetry adapters normalize at the boundary, and
the client's surfaces read standardized queries rather than a vendor's own files.

## 8. Declarative interface contributions

A contribution is **data**. It names one of the client's precompiled primitives,
the resource or action it binds to, and the least profile it needs. Allowed
contributions are `settings`, `command`, `navigation`, `metric-panel` and
`resource-view`; the primitives are form, table, chart, progress, text and action.
Focus, input-method editing, accessibility, theming and prepared-value consistency
belong to those host primitives.

- There is no script field, no widget tree and no direct RPC handle. A downloaded
  package cannot put code into an already-shipped client, and a capability that
  genuinely needs a new primitive negotiates a core version instead of shipping
  one.
- A contribution that needs a profile this host does not serve is not mounted.
  Every other contribution, and every other feature of the client, mounts exactly
  as before; a missing optional package cannot stop an unrelated page from
  building.
- A field may declare that a secret is needed and may not carry one. The host
  collects it in its own control and stores a credential handle; the raw secret
  never enters the contribution's data.
- A prepared value computed for a generation that has been replaced is refused by
  generation, whatever its arrival time says, and no unrelated feature re-reads
  its source on its account.

## 9. Versions

Five versions are identified separately and are never collapsed into one:
the package's own semver, the SDK version, the host ABI, the data schemas and the
renderer profile.

| Change | Outcome |
|:---|:---|
| Incompatible wire major | That extension is refused, and nothing else is |
| Additive minor field | Ignored by a reader that does not know it, and preserved where the field is an extension attribute |
| Required method or capability that cannot be negotiated | The relevant profile or operation is refused, with an actionable recovery |

Package ranges are recorded, not solved, by the planning tools; constraint
resolution, artifact selection and the install journal belong to the host's
package manager. A declaration graph validating does not prove that the code is
separated.

## 10. Trust and permissions

| Rule | Statement |
|:---|:---|
| A manifest has no digest and no signature | The content hash and publisher verification are produced from the bytes by packaging and by the update mechanism. A manifest that declares itself verified is refused |
| A permission request is a request | There is no `granted` field anywhere in the manifest, and a directory listing is not an authorization |
| Consent is explicit | A first install, a widened scope and a new network domain need the user's or an existing policy's agreement. Post-install scripts are not executed by default |
| Local import is legal | A user may import a self-made package or point at an existing adapter process without a marketplace and without signing in. Binding trust to the specific content is enough |
| Isolation is stated honestly | Where the operating system provides file, network and process permissions, they are enforced. Where it does not, the client says it is in trusted local mode instead of implying a sandbox |
| Secrets are brokered | Extensions receive host handles; raw credentials are passed only to a trusted extension that has been granted that specifically |

## 11. Not claimed here

This document does not install, download, execute or verify any package, and it
does not attest that any third-party extension exists or works. It publishes the
contract, the schemas and the rules that the host applies. Install sizes, artifact
inventories and per-platform evidence are separate, measured facts recorded in
release evidence.
