# Security

English · [简体中文](SECURITY.zh-CN.md) · [Home](README.md)

## Report a problem

Use the repository's private vulnerability reporting feature when it is
available. If it is not available, contact a maintainer through a private
channel before sharing details. Do not open a public issue with a working
exploit or private data.

Include only the smallest example needed to reproduce the problem. Use made-up
values and placeholders such as `<repo-root>`, `<user-home>`, `<input-file>`,
and `<peer-id>`.

## Never publish

- Credentials, tokens, private keys, recovery material, or encrypted secrets.
- User messages, files, agent history, or raw tool input and output.
- Local paths, account data, device details, logs, or runtime reports.
- Protected service data or raw command output from a live system.

## Client privacy boundary

LicoUp keeps sensitive runtime data on the device. A peer transfer is
encrypted on the sending client and addressed to another LicoUp client. The
relay is untrusted. LicoUp does not send plaintext user content to it.

An approved external MCP request is a different boundary: HTTPS protects its
transport, but the named service can read the exact body or files the user
approved. It never inherits access to local runtime data or unlisted files.

A manually configured OpenClaw or Hermes VM is also an external plaintext
recipient. LicoUp keeps the exact SSH destination visible, and a direct Send
action authorizes only that prompt to that VM. System OpenSSH authenticates and
encrypts the transport with strict host verification and noninteractive
credentials already configured outside LicoUp. The target model accepts no
password or private key, disables forwarding and connection multiplexing, and
never forwards local MCP server descriptors to the guest.

Plugin installation, enablement, startup, schedules, and agent requests never
authorize an external transfer. A caller-supplied confirmation flag or writable
state file is not approval. The native client command requests fresh platform
user presence for the canonical transfer digest, then atomically claims the
matching short-lived preview exactly once before exchange. The digest binds the
direction, destination, purpose, protocol revision, session, and exact request
body. Each request and each selected local file that would leave the device
requires a fresh, exact approval; missing platform user-presence protection
disables the transfer.

Optional local runners have a separate trust boundary. The signing key is
imported independently of the package download and is protected as authoritative
platform state. Every start verifies the immutable source commit, full signed
inventory, fixed runner, assembled payload, and process identity. Ordinary
client state is only a projection and cannot establish trust.

Read the [architecture guide](docs/architecture/README.md) for the full data boundary.

## Protocol authority and endpoint custody

Lico Arc Protocol owns stable wire-observable Pairwise Protection, Generic
Message, Reliable Exchange, negotiation, and Transport Profile semantics.
LicoUp executes one pinned Protocol Line while retaining private keys, local
Provider configuration, plaintext, conversation history, backups, user trust,
approvals, and local effects. A Station receives none of those authorities.

The [current retiring endpoint-protection Preview](docs/STATUS.md) is not a
Lico Arc Profile or a stable compatibility surface. It has no future
interoperability promise and is to be retired directly when a complete pinned
Lico Arc Protocol Line replaces it. The implemented `licoarc.relay.v1`
candidate outer adapter remains a separate current fact; its existence does
not certify that preview as Lico Arc conformance.

## Relay threat model

An untrusted relay can observe routing fields and ciphertext. It can copy,
drop, delay, reorder, or replay packets. LicoUp does not rely on a claim about
whether the relay stores them. The sender encrypts before network I/O, and the
receiver checks peer identity, packet integrity, and replay state before use.
The client does not send the relay plaintext user content or private keys.

Every transport service is hostile by default. LicoUp pairs with the peer
endpoint, not the transport service. Transport configuration and delivery
requests do not establish station trust. BadTower is an independent Lico Arc
station. LicoUp's direct client-owned adapter uses the pinned
`licoarc.relay.v1` candidate and has completed a bounded two-fresh-endpoint
exchange through an actual BadTower candidate. This local candidate evidence
does not establish station trust, publication, stable support, or hosted
operation.

LicoUp never accepts an encryption algorithm, key, trust root, or security
policy from a relay. Relay acknowledgements, leases, clocks, expiry reports,
and queue state are attacker-controlled delivery hints. They cannot establish
authenticity, integrity, freshness, replay safety, or final peer receipt.
Endpoint cryptographic state and peer-authenticated protocol evidence remain
authoritative for those decisions.

## Current local key custody

The client uses an available platform secret store or an explicit memory-only
store. Memory-only custody requires pairing and new keys after restart. The
current storage interface protects sealed key data at rest, but it does not
prove that every protocol key is hardware-backed or non-exportable.

Where a current platform adapter supports protected access, LicoUp asks for
native user authentication. Cancellation and timeout fail closed. The client
does not accept executable crypto patches from a relay or service.
There is no runtime crypto-patch loader.
