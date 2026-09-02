# LicoUp Product

| Related Document | Language / Path | Authority |
|:---|:---|:---|
| **Normative Version** | English (Normative) | Authoritative product goals & design philosophy |
| **Localization** | [简体中文](PRODUCT.zh-CN.md) | Localized Chinese projection |
| **Current Status** | [docs/STATUS.md](docs/STATUS.md) | Current implementation facts and release evidence |
| **Compatibility Matrix** | [docs/COMPATIBILITY.md](docs/COMPATIBILITY.md) | Platform and 13-agent support matrix |
| **Domain Vocabulary** | [CONTEXT.md](CONTEXT.md) | Unified domain vocabulary definitions |
| **Architecture Root** | [docs/architecture/README.md](docs/architecture/README.md) | 4-tier client architecture overview |
| **Repository Home** | [README.md](README.md) | Repository landing page |

LicoUp is an open-source, local-first human-agent conversation client.

Its durable destination is one secure conversation experience in which people and visible agents participate under user-controlled identity, approval, disclosure, and local-effect boundaries. Infrastructure, providers, cryptography, and execution details remain inspectable without becoming the primary navigation. Current implementation, verification, release, support, and operation facts are recorded only in [`docs/STATUS.md`](docs/STATUS.md) and the generated [`docs/COMPATIBILITY.md`](docs/COMPATIBILITY.md). Repository vocabulary is defined in [`CONTEXT.md`](CONTEXT.md).

## Design Philosophy

- **Diverse** — adapters connect diverse agents and devices without vendor lock-in.
- **Connected** — local tools and peer clients share a clear, transparent flow.
- **Open** — source and client contracts can be reviewed and extended.
- **Integrated** — unified application and bridging contracts isolate UI from concrete adapters.

## Product promise

Users can communicate with their own agents, peer endpoints, and explicitly
admitted external capabilities while retaining control of protected content,
keys, approval, and local effects.

The client asks the operating system for a privacy permission only when the
current user action needs that resource. Automatic Agent discovery resolves
each canonical Agent command through the User's configured command-line
environment without starting the Agent as a probe. This bounded lookup may
consult the shell's PATH, command aliases, functions, wrappers, and shims; it
does not recursively enumerate PATH directories. The Agent Scan Path Manifest
remains supplementary discovery for configuration, history, additional
installations, and LicoUp-managed runtimes. Discovery must not batch Desktop,
Documents, Downloads, Pictures, Music, photo-library, media-library,
network-volume, microphone, camera, or other apps' data prompts. Token usage is
not scanned until Monitoring is opened.

The product remains useful as a local-agent client before human messaging,
federation, recovery, notary, and multi-device goals are delivered. Those
goals become current capability only after their owning implementation and
verification close.

## Agent command identity

Without an explicit Agent Center override, LicoUp must select the same Agent
command that the User's configured command-line environment would select when
the canonical command is entered there. The command-selection boundary
includes shell startup semantics, PATH order, wrappers, version-manager shims,
and any alias or function behavior that contributes a target, arguments, or
environment. LicoUp may collapse that result to a concrete executable only
when doing so is behavior-preserving; otherwise it retains a shell-backed
launch binding instead of silently discarding User configuration.

The Agent Center shows the observed command binding and every additional
candidate. An explicit User selection of a command or version replaces the
observed default. User-configured environment variables, arguments, and Hooks
then extend that selected launch profile with visible, deterministic
precedence. A manifest-discovered or LicoUp-managed runtime may be offered when
the command-line environment has no matching command, but it must never be
presented as the User's terminal choice.

## One conversation model

The long-term model uses one visible Conversation for people and Agents:

- a User can start, continue, search, organize, and preserve conversations;
- a local or remote Agent participates through an explicitly admitted
  interface and never becomes an implicit authority;
- a human or Agent participant receives only the history and context granted
  by the conversation membership policy;
- every external disclosure or effect remains visible, bounded, and
  independently approved;
- local search and projections are built after endpoint-controlled
  decryption.

Provider-native histories may be projected into the experience, but they do
not silently become the canonical LicoUp conversation authority.

## Endpoint responsibility and protocol execution

LicoUp owns:

- endpoint identity material, private-key custody, and local cryptographic
  Provider selection and invocation;
- decrypted plaintext, conversation history, local search projections, and
  user-selected backups;
- conforming execution of one pinned Lico Arc Protocol Line;
- endpoint admission, the User's peer-trust decision, approval, protected
  disclosure, and local effects;
- local persistence and enforcement of protocol-defined freshness, replay,
  recovery, and endpoint-evidence transitions;
- client configuration, native bridges, platform adaptation, packaging, and
  user experience.

Endpoint protection is independent of any station or gateway implementation.
A station response, lease, timestamp, queue state, acknowledgement, or
delivery claim is only an untrusted operational hint.

LicoUp does not own an alternative cryptographic protocol that it may
unilaterally fork. Wire-observable Pairwise Protection, Generic Message,
Reliable Exchange, negotiation, Transport Profile, and protocol-transition
semantics remain governed by versioned Lico Arc Protocol Lines. LicoUp selects
a supported line, holds the endpoint keys and local state, executes that line,
and fails closed when it cannot conform.

## Federation boundary

Lico Arc Protocol is external to LicoUp and is the implementation-neutral
authority for stable wire-observable endpoint communication. It owns
versioned Pairwise Protection, Generic Message, Reliable Exchange,
negotiation, Transport Profile, station-facing contracts, conformance corpora,
and neutral federation governance. It receives no private keys, local Provider
configuration, plaintext, conversation history, backups, user-trust decision,
approval authority, or local-effect authority.

BadTower is the independently versioned single-node Station product. When
released on its own lifecycle, it stores and forwards only opaque Lico Arc
envelopes and remains potentially malicious from the endpoint perspective. It
is not a LicoUp backend and never defines endpoint identity, cryptography,
approval, peer trust, or user experience. Compatibility is established only
through a named Lico Arc Protocol Line and independent conformance evidence;
it never requires a product-specific protocol, linked implementation, or
synchronized release.

## Trust partition

- Lico Arc Protocol owns wire-observable Pairwise Protection, Generic Message,
  Reliable Exchange, negotiation, Transport Profile, federation governance,
  and protocol compatibility.
- LicoUp holds private keys, selects and invokes local Providers, executes a
  pinned Protocol Line, and owns plaintext, history, backups, endpoint
  admission, approval, local effects, and the User's final trust decision.
- A Station owns no trust decision.

These states must remain distinct and must never collapse into a generic
cross-product trust verdict.

## Official network boundary

A LicoLand-operated LicoUp network may become a replaceable convenience
default only after independent release and operation evidence exists. It
receives no cryptographic, identity, admission, certification, revocation,
routing, or disaster-recovery privilege. The client remains usable without
that network. LicoLand Network Host owns only that operator's fleet
deployment and operation evidence; LicoUp continues to own client
default-entry selection and every endpoint trust decision.

## External operation boundary

An External Operation requires fresh direct approval bound to the exact
destination, purpose, scope, and content. Installation, enablement, startup,
scheduling, agent intent, or a prior approval never authorizes a later
external disclosure or effect.

Transport protection does not prevent the approved destination from reading
the exact content deliberately sent to it. A Protected Transfer to a Peer
Endpoint is distinct from an external service request.

A Communication Channel on the Gateway Runtime is an admitted external channel.
Enabling the runtime and approving a Telegram DM pairing grants a scoped bridge
authorization for that bot and Telegram user to exchange ordinary turns with a
bound local Agent. Revoking pairing ends the grant. Content sent through
Telegram remains readable by Telegram.

## Platform and release model

LicoUp targets desktop and mobile platforms through independent adaptation and
release lanes. Development, source verification, platform build,
physical-device verification, packaging, GitHub Release, and every platform
store are separate claims. Evidence from one platform or channel never
promotes another.

## Non-goals

LicoUp does not:

- delegate endpoint security or trust to a station, service, plugin, or
  website;
- define, stabilize, or silently fork a product-specific endpoint wire
  protocol;
- make an official network a mandatory or privileged trust root;
- treat build availability, preview status, generated artifacts, or plans as
  release or support evidence;
- preserve a retired product-specific station wire as a permanent
  compatibility surface.

## Experience principles

- Conversation first; infrastructure stays outside primary navigation.
- Local first; protected client data remains endpoint-controlled.
- Native-agent fidelity is required for every enabled Agent adapter.
- External destinations and effects remain explicit.
- Accessibility targets clear focus, reduced-motion-safe transitions, strong
  contrast, and touch-sized controls.

## License

LicoUp uses AGPL-3.0-or-later. See [`LICENSE`](LICENSE).
