# Agent adapter boundaries

Updated: 2026-09-27

[简体中文](AGENT-ADAPTERS-ARCHITECTURE.zh-CN.md) · [Runtime module](../modules/agent-runtime.md)

## The program boundary

**One Agent, one program, one crate.** Everything that exists because of a specific
Agent — how its process is launched, how its frames are parsed, how its protocol
failures and approval requests are represented, and its own declaration — lives in a
single crate that produces that Agent's adapter artifact. An Agent's code is not split
across two crates, and a crate does not carry two Agents' protocol code. This is a
requirement, not a preference: it is what makes an adapter removable, and a boundary
drawn through the middle of one Agent satisfies neither half.

**How that artifact is reached is the adapter's choice, and more than one shape is
supported.** The contract fixes the *interface*, not the *delivery mechanism*: an Agent
adapter may be **declarative** (facts the host acts on directly, with no adapter code of
its own), a **separate process** the host starts and talks to, or an **existing service**
the host already reaches. A separate process is the fully general shape and the one that
needs no capability from its host, but it is not the only conforming one, and choosing a
declarative or existing-service shape must not force that Agent's code into a shared
crate. What the three share is the requirement below: the client is not recompiled to add,
update or remove the Agent, and all of that Agent's adaptation remains in one crate.

**Such a crate depends on the extension contract and on nothing else in this client.** It
does not depend on Conversation, on the host framework, or on another Agent's crate. Where
the shape is a program, that program is ordinary and exposes **no Rust ABI** to the host —
it is not a trait object and not a dynamic library loaded into the client's address space —
so no compiler version, allocator or panic strategy crosses the boundary, and an adapter
built by a user with a different toolchain is a supported case rather than a fragile one.

**Detachment is structural, not conditional.** Removing the package removes the Agent:
the host reports the capability as unavailable with an actionable recovery and the client
starts normally. There is no feature flag to disable, no recompilation of the client, and
no other Agent is affected. A capability that is absent is a catalogue fact; it is never
a malformed request and never a reason the rest of the client fails.

**The host keeps only what is not any one Agent's.** Discovery and the Agent declarations
as data; the adapter registry; the work-context seam the drivers bind to; the carrier
that starts, handshakes with and supervises an adapter program; and the local service
control plane. **The host contains no vendor protocol branch and no per-Agent parsing.**
If a change to one Agent's wire format can require a change to the host, the boundary is
in the wrong place.

**Where a vendor's protocol is implemented is the adapter's business.** Upstream-version
handling, feature probing and protocol repair stay inside that Agent's program. The core
continues to consume the single semantic facade described below.

## How an adapter reaches a client

An adapter program is delivered as **a package under the extension contract**, not as a
build-time dependency of the client. `licoup-extension-contracts` already owns that
machinery and this section does not add to it; it states which parts an Agent adapter is
required to use.

**A source is a source.** `PackageSource` treats a package the user built on this machine,
a directory on this machine, an official directory and a third-party mirror as equals.
Nothing in the contract requires reaching the network, and **no rule may be satisfiable
only through a hosted catalogue** — downloading an adapter is one way to obtain a package,
never a precondition for using one. Local import requires no registry, no directory service
and no account.

**Installation is the host's, and it is a deployment relation only.** A package's
`requires` decides what is installed with it and `optionalRequires` states that extra
capability becomes available *when the user already has it* — it is never an instruction to
install anything. `CAPABILITY_OWNERSHIP` decides what the minimal distribution carries, and
that distribution remains a complete product on its own.

**Four facts stay independent**: available, installed, enabled and active. An Agent whose
package is absent is reported as an **unavailable capability with an actionable recovery** —
never a malformed request, never a parse error, and never a reason the rest of the client
fails to start. That is the mechanism behind *detachment is structural* above.

**The boundary is the process, and the contract is versioned at that boundary.** An adapter
speaks the extension contract's line-delimited JSON-RPC; it declares the profile methods it
implements and the contract generation it was built against, and the host admits or refuses
it on those declared facts. **An adapter built by a user with a different toolchain is a
supported case**, because no Rust ABI crosses — and a client update therefore does not
silently change what an installed adapter means.

**An adapter is untrusted until it is confined.** The host runs it under the isolation modes
described in `platform/extension_host/isolation`: `TrustedLocal` for a program the user
supplied, with no confinement and a record that says so, or `Restricted`, which refuses to
start unless the platform really enforces the confinement it claims. Nothing downgrades a
restricted request into a trusted run to make it work.

The core consumes one current semantic facade: send input, receive output, control
an admitted turn and resolve approval. Vendor RPC, ACP, MCP, HTTP/SSE and terminal
frames belong to adapters. Keep upstream-version handling there; do not maintain
parallel V1/V2 core contracts or vendor branches in Conversation or Flutter.
External protocol identifiers identify an adapter's wire format, not another core.

Approval describes the decision and its scope: one operation, a supported persistent
scope or a matching prefix, and the corresponding refusal. Never widen a one-time
approval into a persistent grant or simulate an unsupported scope. Preserve actual
capabilities and explicit unsupported results. Usage, pricing and model discovery
have separate owners; they do not enlarge the core send/receive contract.

[Runtime contracts](../../crates/licoup-agent-runtime/src/) and
[extension contracts](../../crates/licoup-extension-contracts/src/agent.rs) own their
executable fields. [Compatibility](../COMPATIBILITY.md) projects registered adapter
facts; do not maintain a second vendor/protocol matrix here.

Keep protocol parsing in each adapter, supervision in the host and durable history
in Conversation. Relay natural replies faithfully: no imposed reply format, no
completion guessed from silence, no silent replacement of an exact resume with a
new session. Respect the user's selected command and environment.

Designers use `npm run repo:impact -- --path <changed-path>` to inspect dependencies.
A vendor-specific change checks that adapter. A shared semantic or transport change
includes its consumers. Update both sides of a changed boundary within one complete
PR; keep shared files under one owner. Missing real validation is a warning, never
proof of support and not a blocker by itself. Run explicitly requested live targets
sequentially. `npm run repo:upstream` observes official source metadata; a page change
requires review and any unrelated protocol repair belongs in a separate Draft PR.
