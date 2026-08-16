# LicoUp Product

English (normative) · [简体中文（本地化）](PRODUCT.zh-CN.md)

LicoUp is an open-source, local-first human-agent conversation client.

Its durable destination is one secure conversation experience in which people
and visible agents participate under user-controlled identity, approval,
disclosure, and local-effect boundaries. Infrastructure, providers,
cryptography, and execution details remain inspectable without becoming the
primary navigation.

Current implementation, verification, release, support, and operation facts
are recorded only in [`docs/STATUS.md`](docs/STATUS.md) and the generated
[`docs/COMPATIBILITY.md`](docs/COMPATIBILITY.md). Repository vocabulary is
defined in [`CONTEXT.md`](CONTEXT.md).

## Product promise

Users can communicate with their own agents, peer endpoints, and explicitly
admitted external capabilities while retaining control of protected content,
keys, approval, and local effects.

The client asks the operating system for a privacy permission only when the
current user action needs that resource. Automatic Agent discovery probes only
named Agent locations in the Agent Scan Path Manifest. Launch, unused-agent
detection, and background catalog work must not walk PATH or batch Desktop,
Documents, Downloads, Pictures, Music, photo-library, media-library,
network-volume, microphone, camera, or other apps' data prompts. Token usage
is not scanned until Monitoring is opened.

The product remains useful as a local-agent client before human messaging,
federation, recovery, notary, and multi-device goals are delivered. Those
goals become current capability only after their owning implementation and
verification close.

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
