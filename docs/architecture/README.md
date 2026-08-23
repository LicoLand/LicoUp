# LicoUp Architecture

| Related Document | Language / Path | Authority |
|:---|:---|:---|
| **Normative Version** | English (Normative) | Authoritative technical architecture specification |
| **Localization** | [简体中文](README.zh-CN.md) | Localized Chinese projection |
| **Product Goal** | [PRODUCT.md](../../PRODUCT.md) | Durable product goal, design philosophy, and promises |
| **Current Status** | [STATUS.md](../STATUS.md) | Current implementation facts and release evidence |
| **Compatibility Matrix** | [COMPATIBILITY.md](../COMPATIBILITY.md) | Platform and 13-agent support matrix |
| **Domain Vocabulary** | [CONTEXT.md](../../CONTEXT.md) | Unified domain vocabulary definitions |
| **Documentation Index** | [docs/README.md](../README.md) | Complete documentation table of contents |

[`PRODUCT.md`](../../PRODUCT.md) owns the durable product goal and boundary. [`../STATUS.md`](../STATUS.md) owns current status. Current component and dependency facts are owned by the Rust/Flutter module trees, `apps/desktop/packaging.modules.json`, and the architecture verifier under `apps/desktop/scripts/client-architecture/`. This document is their public architectural projection.

---

## Security and Public-Source Boundary

[Security & Data Boundaries](SECURITY-AND-DATA-BOUNDARY.md) owns the detailed mechanics. This entry preserves their cross-document invariants:

- A Compatible untrusted station is transport only. The sender emits a Five-field Lico Arc envelope; peer identity, freshness, replay rejection, and authenticated final receipt remain endpoint decisions.
- Local paths, logs, histories, usage records, credentials, and raw runtime data stay on the device. Only approved protected peer content and the protocol's minimal routing fields cross the station boundary.
- Current platform key custody uses operating-system secure storage when available or explicit memory-only custody. Caller-supplied flags or ordinary state files are not proof of approval; protected effects require a platform-held authorization session.
- The client accepts no executable crypto patches from a relay or service, and there is no runtime crypto-patch loader.

Agent conversations remain Rust-hosted. New and native continued sessions keep process-local, wakeable progress; an active turn uses native steer when supported, otherwise an exact-session safe-boundary follow-up. Observer loss is not cancellation or settlement. Subagent MCP addresses only canonical Conversation and Membership identities, while native continuation locations remain private.

---

## Horizontal Tiers & Vertical Domain Slices

LicoUp is structured across **Horizontal Platform Tiers** and **Vertical Domain Slices**:

### 1. Four Horizontal Platform Tiers
1. **Tier 1: Flutter Presentation / Shell Layer** — Pure user appearance, navigation, and interaction views without core business processing logic (any legacy processing logic will be progressively decoupled downward).
2. **Tier 2: Bridging Contract / RPC Protocol Layer** — Bidirectional communication contract between Flutter and Rust (`licoup.stdio.v1` structured method frames and mobile platform FFI commands), strictly precluding raw CLI argument array pass-through.
3. **Tier 3: Rust Functional Core & Infrastructure Layer** — Explicitly bifurcated into:
   - **Rust Domain Core**: Hosts `Canonical Conversation` (dispatch door & turn host), `Adaptive Flywheel` (strategy graphs and route selection), and `Agent Adapters & Runtime` (13 agent vendor protocols and dispatch).
   - **Rust Infrastructure & External Boundary Gateway**: Serves as the clear boundary between internal domain logic and the external physical world, encompassing **Database Storage (SQLite WAL)**, **Dynamic Configuration**, **Secret & Key Custody Facade (Layered atop Native OS)**, **Network & Transport**, and **PTY / TTY & Subprocess Management**.
4. **Tier 4: Native OS / System Adaptation Layer** — Low-level operating system and platform script/API adaptations (macOS Keychain/PTY/launchd; Windows WinCred/ConPTY/PowerShell; Linux Secret Service/XDG; Android JNI/Keystore/SAF; iOS Secure Enclave/FaceID, etc.).

### 2. Vertical Domain Slices
Vertical business capabilities such as **Conversation** operate as end-to-end vertical architectural slices cutting across Flutter presentation views, bridging contracts, Rust domain dispatching, infrastructure persistence, and native operating system environments.

Lico Arc Protocol, not this client repository, owns stable endpoint wire semantics.

---

## Four-tier Architecture Component Diagram

```mermaid
flowchart TB
    subgraph LAYER1["1. Flutter Presentation / Shell Layer"]
        UI["Flutter Views · Navigation · Gestures · Security Summaries<br/>(No core processing logic)"]
    end

    subgraph LAYER2["2. Bridging Contract / RPC Protocol Layer"]
        BRIDGE["licoup.stdio.v1 Structured Method Frames (Desktop RPC)<br/>Platform FFI Commands (Mobile Bridge) · Strict Bidirectional Contract"]
    end

    subgraph LAYER3["3. Rust Functional Core & Infrastructure Layer"]
        subgraph DOMAIN_BOX["Rust Domain Core"]
            CONVERSATIONS["Canonical Conversation Domain<br/>Sole Durable Chat Authority · Memberships · Dispatch Door · Turn Host"]
            STRATEGIES["Adaptive Flywheel Strategy Domain<br/>Immutable Graphs · Route Selection · Durable Runs"]
            AGENTS["Agent Adapters & Runtime<br/>ACP · app-server · RPC · CLI · 13 Packaged Agent Drivers"]
        end

        subgraph INFRA_BOX["Rust Infrastructure & External Boundary Gateway"]
            DB_STORAGE["Database Storage (SQLite / WAL Engine · Transactions · Indices)"]
            DYNAMIC_CONFIG["Dynamic Configuration System (Hot-reload · Manifests · Precedence)"]
            SECRET_CUSTODY["Secret & Key Custody Facade (Key Derivation · Layered atop Native OS)"]
            NET_TRANSPORT["Network & Transport (HTTP/SSE Streams · SSH Tunnels · P2P Envelopes)"]
            PTY_TRANSPORT["PTY / TTY Subprocess Transport (PTY Sessions · Winsize · Process Supervision)"]
        end

        CONVERSATIONS --> DB_STORAGE
        STRATEGIES --> DB_STORAGE
        AGENTS --> NET_TRANSPORT
        AGENTS --> PTY_TRANSPORT
        CONVERSATIONS --> SECRET_CUSTODY
        AGENTS --> DYNAMIC_CONFIG
    end

    subgraph LAYER4["4. Native OS / System Adaptation Layer"]
        MACOS["macOS / Darwin<br/>Swift/ObjC · Keychain · LocalAuth · Launchd · POSIX PTY · Firmlink · OrbStack"]
        WINDOWS["Windows / Win32<br/>PowerShell · MSVC · WinCred · ConPTY/NamedPipe · Registry · %APPDATA%"]
        LINUX["Linux / Ubuntu<br/>GNU Toolchain · D-Bus Secret Service · XDG Specs · Linux PTY · Signals"]
        ANDROID["Android<br/>Kotlin/Java · JNI/FFI · Keystore · BiometricPrompt · SAF · Android Shell"]
        IOS["iOS<br/>Swift · C-ABI FFI · Secure Enclave · FaceID/TouchID · Sandbox Container"]
        COMMON_OS["Cross-Platform System Tooling<br/>OpenSSH Batch Tunnels · Process Supervision (SIGTERM/KILL) · Env Sanitization"]
    end

    LAYER1 --> LAYER2
    LAYER2 --> LAYER3
    SECRET_CUSTODY --> LAYER4
    NET_TRANSPORT --> LAYER4
    PTY_TRANSPORT --> LAYER4
    DB_STORAGE --> LAYER4
    DYNAMIC_CONFIG --> LAYER4
```

---

## Tier and Module Responsibilities

| Tier | Architectural Module | Responsibility Boundary |
|:---|:---|:---|
| **Tier 1: Flutter Presentation Layer** | Flutter User Interface (Shell / UI) | Navigation, views, user interactions, visual styling, and security summaries. Must not contain core business processing logic. |
| **Tier 2: Bridging Contract Layer** | RPC / FFI Communication Contract | Governs Flutter ↔ Rust contract. Desktop uses `licoup.stdio.v1` structured method frames, mobile uses C-ABI FFI commands; strictly prohibits CLI argument array pass-through. |
| **Tier 3: Rust Domain Core** | Canonical Conversation Domain | Sole durable authority for direct/group chat, Human/Agent Memberships, structured Events, and Membership-scoped dispatch; native runtime locations stay private. |
| | Adaptive Flywheel Strategy Domain | Immutable package revisions, JSON Graph validation, bindings, exact authorization, durable run reduction, and bounded effect scheduling independent from Conversation history. |
| | Agent Adapters & Runtime | Translates 13 supported local agent interfaces (ACP, app-server, CLI, RPC) and discovered VM protocol connections. |
| **Tier 3: Rust Infrastructure Layer** | Database Storage (SQLite WAL) | Sole persistence engine providing ACID transactions, typed migrations, and compound indexed query access. |
| | Dynamic Configuration System | Runtime config parsing, dynamic reload/perception, deterministic precedence (CLI > Env > Manifest > Platform defaults). |
| | Secret & Key Custody Facade | Unified security facade directly layered atop Tier 4 Native OS keyrings (Keychain/WinCred/Keystore/Secure Enclave). |
| | Network & Transport | HTTP/SSE streaming client, system batch SSH tunnels, P2P encrypted envelope transport, and connection lifecycles. |
| | PTY / TTY Subprocess Transport | Cross-platform pseudo-terminal abstraction, window size synchronization, ANSI streaming, and process supervision ladders (Grace $\to$ SIGTERM $\to$ SIGKILL). |
| **Tier 4: Native OS Adaptation Layer** | macOS / iOS Adaptation | Swift/ObjC bridge, Keychain secure storage, `LocalAuthentication` biometric confirmation, Launchd autostart, APFS/Firmlink path normalization, OrbStack CLI discovery. |
| | Windows Adaptation | PowerShell/Cmd script wrapping, WinCred credential management, ConPTY pseudo console and named pipes, registry autostart, wide-character paths. |
| | Linux / Ubuntu Adaptation | GNU toolchain, D-Bus Secret Service (with ephemeral fallback), XDG Base Directory/Autostart specs, POSIX PTY, and signal supervisor. |
| | Android Adaptation | Kotlin/Java host integration, `android_ffi.rs` lifecycle bridge, Android Keystore, `BiometricPrompt`, SAF storage, and Android Shell sandbox interaction. |
| | Cross-Platform Tooling & Sandbox | OpenSSH batch tunnels, `process_supervisor.rs` supervision ladders (Grace Period $\to$ SIGTERM $\to$ SIGKILL), and environment variable sanitization allowlists. |

---

## Native OS Adaptation Boundary

The shared Rust functional core and Flutter presentation layer remain platform-neutral. Tier 4 "Native OS Adaptation Layer" owns the low-level operating system APIs, scripts, and platform-specific toolchains:

| Platform / Tooling Domain | Native System Adaptation Responsibilities |
|:---|:---|
| **macOS (Darwin / Swift / Unix)** | 1. **Security & Presence**: `Security.framework` (Keychain Services) and `LocalAuthentication.framework` (Touch ID / Apple Watch auth);<br>2. **Daemons & Autostart**: `~/Library/LaunchAgents/` launchd plist management and `launchctl bootstrap / bootout` scheduling;<br>3. **Terminal & Sandbox**: POSIX PTY (`openpty`, `termios`, `ioctl(TIOCSCTTY)`, `winsize`), APFS Firmlink system and data volume mapping;<br>4. **VM Probing**: OrbStack local Unix Domain Socket probing and `orb` CLI discovery. |
| **Windows (Win32 / PowerShell / MSVC)** | 1. **Credentials & Storage**: Windows Credential Manager (WinCred `CredReadW`/`CredWriteW`) secure custody;<br>2. **Terminal & Console**: Windows Pseudo Console API (ConPTY: `CreatePseudoConsole`) and Windows Named Pipes;<br>3. **Autostart & Registry**: Windows Registry Run key (`HKCU\Software\Microsoft\Windows\CurrentVersion\Run`) and Task Scheduler;<br>4. **Script Wrapping**: PowerShell / Cmd script wrapping (`Get-Command`, `.cmd`/`.ps1`), safe argument quoting, and wide-character path resolution. |
| **Linux / Ubuntu (GNU / POSIX / D-Bus)** | 1. **Secret Service**: D-Bus Freedesktop Secret Service spec (libsecret / GNOME Keyring / KWallet) with ephemeral in-memory fallback;<br>2. **System Standards**: XDG Base Directory spec (`$XDG_DATA_HOME`, `$XDG_CONFIG_HOME`) and XDG Autostart (`~/.config/autostart/*.desktop`);<br>3. **Terminal & Processes**: Linux PTY (`forkpty`, `ptsname`, `grantpt`), standard signal trapping, and `/proc` process-tree tracking. |
| **Android (Kotlin / Java / Android Shell)** | 1. **Host & Lifecycle**: `android_ffi.rs` JNI bridge, managing lifecycle across Android Activity/Service events and memory trimming;<br>2. **Hardware Keys & Auth**: Android Keystore System and `BiometricPrompt` hardware fingerprint/face confirmation;<br>3. **Storage & Shell**: Storage Access Framework (SAF), app private sandbox directories, and Android Toybox/Termux Shell sandbox interaction. |
| **iOS (Swift / ObjC / C-ABI FFI)** | 1. **FFI Integration**: `ios_ffi.rs` C-ABI memory-safe bridge, managing single-process restricted execution lifecycle;<br>2. **Hardware Storage & Auth**: Apple Secure Enclave hardware Keychain access and `LocalAuthentication` (Face ID / Touch ID);<br>3. **Sandbox & Container**: `NSApplicationSupportDirectory` sandbox paths and background execution constraints handling. |
| **Cross-Platform System Tooling** | 1. **Network Tunnels**: OpenSSH batch mode (`ssh -o BatchMode=yes -o StrictHostKeyChecking=yes`) interactive-free secure tunnels;<br>2. **Process Supervision**: `process_supervisor.rs` supervision ladders (Grace Period $\to$ SIGTERM $\to$ SIGKILL) and environment variable sanitization allowlists. |

---

## Domain Architecture Index

To maintain clarity across the four primary architectural tiers, detailed domain-specific designs are separated into dedicated documents:

| Architecture Domain | Architectural Tier | Specification Document | Domain Responsibilities |
|:---|:---|:---|:---|
| **Client-Native Interaction** | Tier 2: Bridging Contract Layer | [CLIENT-NATIVE-INTERACTION.md](CLIENT-NATIVE-INTERACTION.md) | `licoup.stdio.v1` structured method frames and mobile FFI command contracts |
| **Canonical Conversation Vertical** | Vertical Slice (Tiers 1 ~ 4) | [CONVERSATION-DOMAIN.md](CONVERSATION-DOMAIN.md) | Bidirectional binding, direct chat base with group orchestration encapsulation, state machine & end-to-end flows |
| **Agent Adapters & Runtime Architecture** | Tier 3: Rust Functional Core | [AGENT-ADAPTERS-ARCHITECTURE.md](AGENT-ADAPTERS-ARCHITECTURE.md) | 13-agent driver taxonomy, standard protocols (ACP/RPC/PTY) vs proprietary (Codex/OpenCode) normalization |
| **Rust Infrastructure & Boundaries** | Tier 3: Infra & Boundary Gateway | [RUST-INFRASTRUCTURE-LAYER.md](RUST-INFRASTRUCTURE-LAYER.md) | Database (SQLite WAL), dynamic config, secret custody facade, transport, PTY/TTY |
| **Adaptive Flywheel** | Tier 3: Rust Functional Core | [ADAPTIVE-FLYWHEEL.md](../functionality/ADAPTIVE-FLYWHEEL.md) | Immutable Graph revisions, route selection, and durable run reduction |
| **Subagent MCP** | Tier 3: Rust Functional Core | [subagent-mcp.md](../protocols/subagent-mcp.md) | Assistant goal ownership, profile facts, and temporary Graph admission |
| **Semantic Conversation** | Tier 3: Rust Functional Core | [semantic-conversation.md](../protocols/semantic-conversation.md) | 13 agent protocol translations, native catalog discovery, and read-only replay |
| **Security & Data Boundaries** | Tier 3: Rust Functional Core | [SECURITY-AND-DATA-BOUNDARY.md](SECURITY-AND-DATA-BOUNDARY.md) | VM discovery isolation, endpoint protection preview, platform secret custody, zero-trust data |
| **Platform System Bridges** | Tier 4: Native OS Adaptation | `crates/licoup-native/src/platform/` | Low-level OS APIs and system tooling for macOS, Windows, Linux, Android, iOS |

---

## Repository Structure

| Path | Purpose |
|:---|:---|
| `apps/desktop/` | Flutter desktop and mobile client (Tier 1 and parts of Tier 2) |
| `crates/licoup-native/` | Rust client core, commands, and platform bridges (Tier 3 and Tier 4) |
| `crates/licoup-conversation/` | (Target) Extracted Conversation domain crate |
| `crates/licoup-agent-runtime/` | (Target) Extracted Agent Runtime and adapter crate |
| `crates/licoup-platform-bridges/` | Native platform ABI and handle management (Tier 4) |
| `crates/licoup-endpoint-core/` | Endpoint identity, key custody, crypto foundations |
| `crates/licoup-protocol-bindings/` | Protocol type definitions |
| `crates/licoup-client-state/` | Client state management contracts |
| `crates/licoup-agent-adapters/` | Agent adapter trait definitions |
| `crates/lico-catalog-convergence/` | Catalog convergence logic |
| `packages/contracts/client/` | Client-owned schemas (Tier 2) |
| `tests/` | Contract and boundary tests with synthetic data |
| `tools/` | Reusable build and validation tools |

Plans, temporary scripts, local skills, raw evidence, and runtime data belong to local working materials and do not enter public source.

---

## Current Architecture Debt & Migration Status

> This section documents known structural problems and the approved migration path.
> It is maintained alongside the living codebase and updated as migration progresses.

### Known Structural Problems (as of 2026-08-24)

| Problem | Severity | Location | Impact |
|:---|:---|:---|:---|
| **God Object `ClientController`** | Critical | `apps/desktop/lib/src/application/controller/` | 452-line constructor, 19+ mixins sharing one `ChangeNotifier`. Any state change triggers full-tree notification. Untestable in isolation. |
| **Mixin abuse as decomposition** | High | `application/controller/`, `application/features/agents/conversation/` | 25+ mixins on a single inheritance chain; shared `this` means no encapsulation. |
| **Monolithic Rust crate** | High | `crates/licoup-native/` (302K lines) | `domain/` has 48 entries, `core/` has 52 entries. Compilation slow, boundaries unclear. |
| **Contracts layer bloat** | Medium | `apps/desktop/lib/src/contracts/` (93 files, 15K lines) | Mixes models, interfaces, parsing logic, and generated code in one flat namespace. |
| **Giant Widget files** | Medium | `frontend/features/` | `canonical_group_conversation_pane.dart` (2603 lines), `agent_conversation_workspace.dart` (1390 lines). |
| **Vestigial backend layer** | Low | `apps/desktop/lib/src/backend/` (2K lines) | Too thin to provide real abstraction; logic leaks into `application/` and `platform/`. |
| **Manual JSON-RPC bridge** | High | `platform/native_client/` ↔ Rust `bin/licoup/stdio_rpc/` | No codegen, schema drift causes runtime failures, no backpressure. |

### Target Architecture (Migration Destination)

#### Flutter App (`apps/desktop/lib/src/`)

```
src/
├── core/                    # Shared foundation (NO business logic)
│   ├── bridge/              # flutter_rust_bridge v2 generated codecs
│   ├── models/              # Generated immutable Rust projections
│   ├── errors/              # Typed error hierarchy
│   └── extensions/          # Pure Dart utilities
├── features/                # Vertical feature slices (self-contained)
│   ├── conversation/        # Main conversation feature
│   │   ├── domain/          # Feature-local contracts & models
│   │   ├── application/     # Riverpod providers (AsyncNotifier per concern)
│   │   └── presentation/    # Widgets, pages, components
│   ├── agent_hub/           # Agent discovery & installation
│   ├── settings/            # App settings & updates
│   ├── skill_hub/           # Skill management
│   ├── mobile_relay/        # Mobile relay & secure mesh
│   ├── models_management/   # LLM model/provider config
│   ├── plugin_management/   # Optional collaboration plugins
│   └── targets/             # Local agent target scanning
├── shell/                   # App shell (composes features into layout)
│   ├── layout/              # Layout system & responsive surfaces
│   ├── navigation/          # Destination routing
│   └── chrome/              # Window chrome & platform decorations
└── shared/                  # Cross-feature shared UI
    ├── widgets/             # Reusable components
    ├── theme/               # Theme data & color schemes
    └── l10n/                # Localization
```

**Key decisions:**
- State management: **Riverpod** (compile-time safe, no BuildContext dependency, auto-dispose, AsyncNotifier for async flows)
- Bridge: **flutter_rust_bridge v2** (in-process FFI with codegen, replacing manual stdio JSON-RPC)
- Each feature is a self-contained vertical slice; cross-feature dependencies go through `core/models/`
- The god `ClientController` is decomposed into per-feature Riverpod providers

#### Rust Crates (Target Decomposition)

```
crates/
├── licoup-native/              # Thin shell: FFI exports + binary entry points only
├── licoup-conversation/        # Conversation domain (identity, membership, events, turns)
├── licoup-agent-runtime/       # Agent host + 13 adapter drivers + transport supervision
├── licoup-endpoint-core/       # Endpoint identity, key derivation, crypto
├── licoup-protocol-bindings/   # Wire protocol types
├── licoup-client-state/        # Client state contracts
├── licoup-platform-bridges/    # OS-specific bridges (Keychain, WinCred, etc.)
├── licoup-agent-adapters/      # Agent adapter trait definitions
└── lico-catalog-convergence/   # Catalog management
```

**Key decisions:**
- `licoup-native` becomes a thin FFI/bin shell importing domain crates
- `licoup-conversation` owns the Conversation bounded context exclusively
- `licoup-agent-runtime` owns adapter lifecycle and the persistent host
- Crate boundaries enforce compile-time dependency isolation

### Migration Strategy

The migration follows three sequential phases:

1. **Phase 1: Infrastructure** (current milestone)
   - Introduce flutter_rust_bridge v2 alongside existing stdio RPC
   - Add Riverpod to pubspec, create first provider wrappers around existing controllers
   - Create target directory structure (done)
   - Establish linting rules preventing new code in legacy locations

2. **Phase 2: Feature Extraction** (feature-by-feature, least-coupled first)
   - Migrate `settings` feature first (least dependencies)
   - Then `agent_hub`, `skill_hub`, `targets`
   - Then `conversation` (most complex, last)
   - Each migration: extract domain → create providers → move widgets → delete old code

3. **Phase 3: Rust Crate Extraction**
   - Extract `licoup-conversation` from `licoup-native/src/domain/`
   - Extract `licoup-agent-runtime` from `licoup-native/src/platform/`
   - `licoup-native` becomes thin FFI shell
   - Remove stdio JSON-RPC path (desktop uses in-process FFI like mobile)
