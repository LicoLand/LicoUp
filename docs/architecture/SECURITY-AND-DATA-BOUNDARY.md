# Security Architecture and Data Boundaries

English (Normative) · [简体中文](SECURITY-AND-DATA-BOUNDARY.zh-CN.md) · [Back to Architecture README](README.md)

This document defines LicoUp client security boundaries, data flow rules, virtual machine integration isolation, and endpoint encryption standards.

## 1. Virtual Machine Discovery and Remote Protocol Boundaries

For OpenClaw and Hermes, the desktop client enumerates running local OrbStack VMs via bounded commands and checks fixed official and standard binary locations; it does not read VM configuration or history. Rust validates the VM name and returned absolute path before creating a temporary `machine@orb` route. Discovered VM routes do not enter the discovery cache.

For other VMs, Flutter collects hostname, optional port/user, in-VM binary, and absolute working directory; Rust validates a closed connection structure and persists it only in authoritative manual targets. Passwords, private keys, command fragments, relative directories, and unknown fields are rejected.

The native core starts the platform system `ssh` executable in batch mode with strict host-key checking, no TTY, no forwarding, no local command execution, no environment forwarding, and no connection multiplexing:
```bash
ssh -o BatchMode=yes -o StrictHostKeyChecking=yes <user>@<host> <command>
```
It passes one fixed, shell-quoted guest command. Both ACP and Hermes TUI gateway protocols use bounded JSON-RPC over stdin/stdout.

## 2. Retiring Endpoint-Protection Preview Layers

The current retiring endpoint-protection Preview uses a fixed security profile:

```mermaid
flowchart TB
    ID["Peer identity<br/>Ed25519 signatures"] --> SETUP["Session setup<br/>X25519 + ML-KEM-1024"]
    SETUP --> DERIVE["Key derivation and ratchets<br/>HKDF-SHA256"]
    DERIVE --> CONTENT["Message protection<br/>ChaCha20-Poly1305"]
    CONTENT --> VERIFY["Verify before use<br/>no plaintext fallback"]
```

Algorithms are combined only when they have distinct roles and validated compositions. The profile locks during the initial handshake. Missing or failed security checks strictly prohibit fallback to plaintext communication.

## 3. Platform Secret Custody

The client probes platform capabilities and selects system secure storage when available, otherwise explicitly falling back to ephemeral in-memory storage. Private key custody and local Provider selection remain LicoUp responsibilities; wire-observable profiles and negotiation belong to the fixed Lico Arc Protocol Line.

## 4. Data Boundaries and Rules

```mermaid
sequenceDiagram
    participant A as Client A
    participant R as Compatible untrusted station
    participant B as Client B
    A->>A: User selects B and approves content
    A->>A: Encrypt for B
    A->>R: 5-field Lico Arc envelope
    R->>B: Forward opaque protected payload
    B->>B: Authenticate, verify freshness/replay, and decrypt
```

The client strictly adheres to these data boundaries:
- **Data Locality**: Local paths, logs, history, usage records, credentials, and raw runtime data stay on-device.
- **Plaintext Control**: Default scenarios never send sensitive runtime data or user content in plaintext to servers.
- **Controlled Disclosure**: External MCP requests contain only exact text and files shown in one-shot user confirmations.
- **Ciphertext in Transit**: Content leaving the client without explicit external service confirmation must be encrypted for the designated peer.
- **Encrypt-then-Send, Verify-then-Use**: Senders encrypt before network transmission; receivers authenticate and verify freshness/anti-replay before consumption.
- **Zero-Trust Stations**: Compatible stations are outside the trusted boundary. Private keys and approval policies stay entirely with endpoints.
- **Safe Summaries**: Logs and reports retain only security summaries, never raw user content or secret keys.
