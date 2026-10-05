export async function checkRuntimeDriversAndLocalService(context, {
  reviewedRustUnsafeFiles,
} = {}) {
  const {
    assert,
    collectDartSourceFiles,
    collectEnumValues,
    collectRustPubMods,
    collectRustUnsafeFiles,
    collectSourceFiles,
    exists,
    fail,
    lineNumberForToken,
    moduleSupportsPlatform,
    readDartSourceByBasename,
    readImmediateDirectoryNames,
    readJoinedDartSourcesByBasename,
    readJoinedText,
    readJson,
    readText,
    runJson,
    sameSet,
  } = context;
  assert(
    reviewedRustUnsafeFiles instanceof Set,
    "runtime-driver checks require reviewedRustUnsafeFiles from crate-core stage",
  );
  const claudeCodeDriverFacadeSource = await readText(
    "crates/licoup-agent-claude-code/src/driver.rs"
  );
  const claudeCodeDriverFiles = await collectSourceFiles(
    "crates/licoup-agent-claude-code/src/driver",
    ".rs"
  );
  const claudeCodeDriverSource = await readJoinedText([
    "crates/licoup-agent-claude-code/src/driver.rs",
    ...claudeCodeDriverFiles
  ]);
  // The vendor protocol, its parser and the launch vocabulary moved into the
  // Claude Code adapter package; the client keeps the process half and reads
  // the package rather than holding a second copy.
  const claudeCodePackageRoot = "crates/licoup-agent-claude-code/src";
  const claudeCodeFoundationSource = await readJoinedText([
    "crates/licoup-agent-claude-code/src/driver/failure.rs",
    "crates/licoup-agent-claude-code/src/driver/reset.rs"
  ]);
  const claudeCodeCommandSource = await readJoinedText([
    `${claudeCodePackageRoot}/protocol/launch.rs`,
    `${claudeCodePackageRoot}/protocol/params.rs`,
    "crates/licoup-agent-claude-code/src/driver/launch.rs"
  ]);
  const claudeCodeParserSource = await readJoinedText([
    `${claudeCodePackageRoot}/protocol/parser.rs`,
    `${claudeCodePackageRoot}/protocol/parser/adapter.rs`,
    `${claudeCodePackageRoot}/protocol/parser/events.rs`,
    `${claudeCodePackageRoot}/protocol/parser/state.rs`
  ]);
  const claudeCodeEventsSource = await readText(
    `${claudeCodePackageRoot}/protocol/parser/events.rs`
  );
  const claudeCodeProtocolSource = await readText(
    `${claudeCodePackageRoot}/protocol/parser/state.rs`
  );
  const claudeCodePackageSources = await readJoinedText([
    `${claudeCodePackageRoot}/lib.rs`,
    `${claudeCodePackageRoot}/registration.rs`,
    `${claudeCodePackageRoot}/replay.rs`,
    `${claudeCodePackageRoot}/port/execution.rs`,
    `${claudeCodePackageRoot}/protocol/mod.rs`,
    `${claudeCodePackageRoot}/protocol/control.rs`,
    `${claudeCodePackageRoot}/protocol/failure.rs`,
    `${claudeCodePackageRoot}/protocol/parser.rs`,
    `${claudeCodePackageRoot}/protocol/parser/adapter.rs`,
    `${claudeCodePackageRoot}/protocol/parser/events.rs`,
    `${claudeCodePackageRoot}/protocol/parser/state.rs`
  ]);
  // The package's own code, with comment lines dropped: a doc comment may name
  // the client boundary, a code path may not cross it.
  const claudeCodePackageCode = claudeCodePackageSources
    .split("\n")
    .filter((line) => !/^\s*(?:\/\/|\*|\/\*)/u.test(line))
    .join("\n");
  const claudeCodeTransportSource = await readText(
    "crates/licoup-agent-claude-code/src/driver/transport.rs"
  );
  const claudeCodeSupervisionSource = await readText(
    "crates/licoup-agent-claude-code/src/driver/supervision.rs"
  );
  // The protocol, the process half and the driver root are one package's since
  // VENDOR-CODE-REMOVAL. The host reads the owning package for the driver's
  // facts and this host for the opposite fact: neither the retired driver tree
  // nor the facade that re-exported the package is left behind. The retired
  // paths are named, so a kernel copy reappearing fails this check instead of
  // quietly becoming a second owner of one Agent's wire.
  const hostKeepsNoClaudeCodeDriver = (await Promise.all([
    "crates/licoup-native/src/platform/claude_code_driver.rs",
    "crates/licoup-native/src/platform/claude_code_driver",
  ].map((relativePath) => exists(relativePath)))).every((present) => !present) &&
    !(await readText("crates/licoup-native/src/platform/mod.rs"))
      .includes("mod claude_code_driver;");
  assert(
    !claudeCodeDriverFacadeSource.includes("Command::new") &&
      !claudeCodeDriverFacadeSource.includes("struct TurnState") &&
      !claudeCodeDriverFacadeSource.includes("struct PersistentTransport") &&
      !claudeCodeDriverFacadeSource.includes("include!(") &&
      !claudeCodeDriverFacadeSource.includes("#[path"),
    "Claude Code driver root must expose only ordinary modules and stable re-exports"
  );
  assert(
    claudeCodeCommandSource.includes("FIXED_STREAM_ARGS") &&
      claudeCodeCommandSource.includes('"--input-format"') &&
      claudeCodeCommandSource.includes('"stream-json"') &&
      !claudeCodeCommandSource.includes('"--no-session-persistence"') &&
      claudeCodeCommandSource.includes('args.extend(["--resume".to_string(), session_id.clone()])') &&
      // The package's protocol names no client crate: one copy, below the port.
      // Documentation may name the boundary it keeps, so the check reads code.
      !claudeCodePackageCode.includes("crate::platform") &&
      !claudeCodePackageCode.includes("licoup_native") &&
      !claudeCodePackageCode.includes("licoup-native") &&
      // The driver reads the protocol beside it — `crate::protocol`, in the
      // package that owns it — rather than the host facade's deleted
      // `licoup_agent_claude_code::protocol` re-export, and the host keeps no
      // driver copy at all. One copy, below the port.
      claudeCodeDriverSource.includes("use crate::protocol") &&
      !claudeCodeDriverSource.includes("licoup_agent_claude_code::protocol") &&
      !claudeCodeDriverSource.includes("super::protocol::") &&
      hostKeepsNoClaudeCodeDriver &&
      claudeCodeDriverSource.includes("MAX_POOLED_TRANSPORTS") &&
      claudeCodeDriverSource.includes("MAX_TRACKED_SESSIONS") &&
      claudeCodeDriverSource.includes("MAX_PROTOCOL_LINE_BYTES") &&
      claudeCodeDriverSource.includes("BoundedStdinWriter") &&
      claudeCodeDriverSource.includes("finish_protocol_transport") &&
      !claudeCodeDriverSource.includes('Command::new("sh")') &&
      !claudeCodeDriverSource.includes('Command::new("cmd")') &&
      !claudeCodeDriverSource.includes('Command::new("powershell")'),
    "Claude Code driver split must retain fixed streaming input, exact live continuation, bounded IO, and cleanup"
  );
  assert(
    claudeCodeParserSource.includes("ClaudeCodeParser") &&
      claudeCodeParserSource.includes("fn parse_line") &&
      claudeCodeParserSource.includes("processing_evidence_kind"),
    "Claude Code parser adapter must own the sole raw-frame ingress, turn state, and redacted event projection"
  );
  // The failure shape and the transport-reset policy name the package's
  // protocol and nothing else in the driver: neither reads the parser, the
  // transport, the supervision registry or the process leaves.
  for (const dependency of [
    "LaunchIdentity",
    "ClaudeCodeParser",
    "transport::",
    "supervision::",
    "execution::",
    "control::",
    "probe::",
    "io::"
  ]) {
    assert(
      !claudeCodeFoundationSource.includes(dependency),
      `Claude Code failure and result foundations must not depend on ${dependency}`
    );
  }
  for (const dependency of ["execution::", "supervision::", "transport::"]) {
    assert(
      !claudeCodeCommandSource.includes(dependency),
      `Claude Code launch identity must not depend on ${dependency}`
    );
  }
  for (const dependency of [
    "launch::",
    "control::",
    "execution::",
    "io::",
    "params::",
    "supervision::",
    "transport::"
  ]) {
    assert(
      !claudeCodeEventsSource.includes(dependency),
      `Claude Code event projection must not depend on ${dependency}`
    );
  }
  for (const dependency of ["control::", "execution::", "io::", "supervision::", "transport::"]) {
    assert(
      !claudeCodeProtocolSource.includes(dependency),
      `Claude Code turn state must not depend on ${dependency}`
    );
  }
  // The transport lifecycle reads the launch identity the package's own
  // protocol owns: `crate::protocol::LaunchIdentity`, not the kernel leaf's
  // deleted `super::launch::LaunchIdentity`. Reading the package's protocol is
  // the invariant the move establishes, so it is required below rather than
  // forbidden; only the sibling process leaves stay out of the transport, and a
  // host re-export reappearing fails here.
  for (const dependency of ["events::", "execution::", "supervision::"]) {
    assert(
      !new RegExp(`\\b${dependency}`, "u").test(claudeCodeTransportSource),
      `Claude Code transport lifecycle must not depend on ${dependency}`
    );
  }
  assert(
    claudeCodeTransportSource.includes("use crate::protocol::LaunchIdentity;") &&
      !claudeCodeTransportSource.includes("super::protocol::") &&
      !claudeCodeTransportSource.includes("super::launch::LaunchIdentity") &&
      !claudeCodeTransportSource.includes("licoup_agent_claude_code::"),
    "Claude Code transport lifecycle must read the launch identity its own package owns, never a host re-export"
  );
  assert(
    claudeCodeSupervisionSource.includes("Arc::downgrade") &&
      !claudeCodeSupervisionSource.includes("ClaudeCodeParser") &&
      !claudeCodeSupervisionSource.includes("processing_evidence_kind"),
    "Claude Code live-session registry must remain independent of parser state and event projection"
  );
  assert(
    !claudeCodeDriverSource.includes("unsafe {") &&
      !reviewedRustUnsafeFiles.has(
        "crates/licoup-agent-claude-code/src/driver.rs"
      ),
    "Claude Code driver must not retain unsafe or a stale unsafe ownership exemption"
  );

  const openClawDriverFacadeSource = await readText(
    "crates/licoup-agent-openclaw/src/driver.rs"
  );
  const openClawDriverFiles = await collectSourceFiles(
    "crates/licoup-agent-openclaw/src/driver",
    ".rs"
  );
  const openClawDriverSource = await readJoinedText([
    "crates/licoup-agent-openclaw/src/driver.rs",
    ...openClawDriverFiles
  ]);
  // The protocol vocabulary moved to the OpenClaw adapter package, which is its
  // own crate and program. The check reads the owning package for it, exactly as
  // the Codex section reads `licoup-agent-codex`, and the kernel path is only the
  // re-export that keeps the driver leaves on one name.
  const openClawPackageSource = await readJoinedText([
    "crates/licoup-agent-openclaw/src/parser.rs",
    "crates/licoup-agent-openclaw/src/parser/protocol.rs",
    "crates/licoup-agent-openclaw/src/gateway_acp/model.rs",
    "crates/licoup-agent-openclaw/src/gateway_acp/errors.rs",
    "crates/licoup-agent-openclaw/src/gateway_acp/params.rs",
    "crates/licoup-agent-openclaw/src/gateway_acp/continuity.rs"
  ]);
  // The seven leaves VENDOR-CODE-REMOVAL moved into this package. They are the
  // package's own implementations at their own paths now, not the host's
  // re-export shims, and the host's `platform/openclaw_driver` tree — module
  // declaration, facade file and leaf directory — is gone. Both facts are read
  // below, so either a shim or a kernel copy reappearing fails the check
  // instead of becoming a second owner of the Gateway protocol.
  const openClawPackageLeafSource = await readJoinedText([
    "crates/licoup-agent-openclaw/src/parser/codec.rs",
    "crates/licoup-agent-openclaw/src/gateway_acp/continuity.rs",
    "crates/licoup-agent-openclaw/src/gateway_acp/errors.rs",
    "crates/licoup-agent-openclaw/src/parser/events.rs",
    "crates/licoup-agent-openclaw/src/gateway_acp/model.rs",
    "crates/licoup-agent-openclaw/src/gateway_acp/params.rs",
    "crates/licoup-agent-openclaw/src/parser/protocol.rs"
  ]);
  const hostKeepsNoOpenClawDriver = (await Promise.all([
    "crates/licoup-native/src/platform/openclaw_driver.rs",
    "crates/licoup-native/src/platform/openclaw_driver",
  ].map((relativePath) => exists(relativePath)))).every((present) => !present) &&
    !(await readText("crates/licoup-native/src/platform/mod.rs"))
      .includes("mod openclaw_driver;");
  const openClawFoundationSource = await readJoinedText([
    "crates/licoup-agent-openclaw/src/gateway_acp/errors.rs",
    "crates/licoup-agent-openclaw/src/gateway_acp/model.rs",
    "crates/licoup-agent-openclaw/src/gateway_acp/params.rs"
  ]);
  const openClawContinuitySource = await readText(
    "crates/licoup-agent-openclaw/src/gateway_acp/continuity.rs"
  );
  const openClawParserSource = await readJoinedText([
    "crates/licoup-agent-openclaw/src/parser.rs",
    "crates/licoup-agent-openclaw/src/parser/codec.rs",
    "crates/licoup-agent-openclaw/src/parser/events.rs",
    "crates/licoup-agent-openclaw/src/parser/protocol.rs"
  ]);
  const openClawEventsSource = await readText(
    "crates/licoup-agent-openclaw/src/parser/events.rs"
  );
  const openClawProtocolSource = await readText(
    "crates/licoup-agent-openclaw/src/parser/protocol.rs"
  );
  const openClawSupervisionSource = await readText(
    "crates/licoup-agent-openclaw/src/driver/supervision.rs"
  );
  const openClawProbeSource = await readText(
    "crates/licoup-agent-openclaw/src/driver/probe.rs"
  );
  assert(
    !openClawDriverFacadeSource.includes("Command::new") &&
      !openClawDriverFacadeSource.includes("struct OpenClawProtocol") &&
      !openClawDriverFacadeSource.includes("include!(") &&
      !openClawDriverFacadeSource.includes("#[path") &&
      // The package's driver root binds its own process leaves and reads the
      // protocol beside it at its own path. The host facade's `mod protocol;`
      // and `mod continuity;` re-export shims are the shape the move deleted,
      // so either one reappearing fails, and so does the host keeping any
      // OpenClaw driver module at all.
      openClawDriverFacadeSource.includes("mod execution;") &&
      openClawDriverFacadeSource.includes("mod supervision;") &&
      openClawDriverFacadeSource.includes("pub use crate::gateway_acp::model::") &&
      !openClawDriverFacadeSource.includes("mod protocol;") &&
      !openClawDriverFacadeSource.includes("mod continuity;") &&
      hostKeepsNoOpenClawDriver,
    "OpenClaw driver root must bind its own process leaves and read the package protocol at its own path, never a second file copy"
  );
  assert(
    // Each of the seven leaves owns the vocabulary it names — the protocol
    // state machine, the codec, the continuity binding, the update projection,
    // the run/failure model and the request validation — and none of them is a
    // re-export of something else. A shim (`pub use licoup_agent_openclaw::…`)
    // or a thin second file fails here.
    openClawPackageLeafSource.includes("pub struct OpenClawProtocol") &&
      openClawPackageLeafSource.includes("impl ProtocolConfig") &&
      openClawPackageLeafSource.includes("pub struct SessionBinding") &&
      openClawPackageLeafSource.includes("pub enum DecodeFailure") &&
      openClawPackageLeafSource.includes("pub fn projected_event") &&
      openClawPackageLeafSource.includes("pub const RUNTIME_PROTOCOL") &&
      openClawPackageLeafSource.includes("pub struct ProtocolFailure") &&
      !openClawPackageLeafSource.includes("licoup_agent_openclaw") &&
      !openClawPackageLeafSource.includes("Command::new") &&
      !openClawPackageLeafSource.includes("include!(") &&
      !openClawPackageLeafSource.includes("#[path"),
    "each moved OpenClaw leaf must be the package's own implementation at its own path, never a re-export shim or a second file copy"
  );
  assert(
    openClawSupervisionSource.includes(
      'ATTACH_ARGS_PREFIX: &[&str] = &["acp", "--url"]'
    ) &&
      openClawSupervisionSource.includes("Command::new(&self.executable)") &&
      openClawProbeSource.includes(".stderr(Stdio::null())") &&
      openClawDriverSource.includes("BoundedStdinWriter") &&
      openClawDriverSource.includes("finish_protocol_transport") &&
      openClawDriverSource.includes("SessionBinding") &&
      !openClawDriverSource.includes('Command::new("sh")') &&
      !openClawDriverSource.includes('Command::new("cmd")') &&
      !openClawDriverSource.includes('Command::new("powershell")'),
    "OpenClaw driver split must retain fixed Gateway ACP, exact continuity, bounded IO, and cleanup"
  );
  assert(
    openClawParserSource.includes("struct OpenClawProtocol") &&
      openClawParserSource.includes("fn handle_frame") &&
      openClawParserSource.includes("projected_event") &&
      !openClawParserSource.includes("update.payload().clone()"),
    "OpenClaw parser adapter must own the sole raw-frame ingress, protocol state, and allowlisted event projection"
  );
  for (const dependency of [
    "continuity::",
    "codec::",
    "execution::",
    "io::",
    "probe::",
    "protocol::",
    "supervision::"
  ]) {
    assert(
      !openClawFoundationSource.includes(dependency),
      `OpenClaw result, error, and parameter foundations must not depend on ${dependency}`
    );
  }
  for (const dependency of ["events::", "execution::", "protocol::", "supervision::"]) {
    assert(
      !openClawContinuitySource.includes(dependency),
      `OpenClaw continuity must not depend on ${dependency}`
    );
  }
  for (const dependency of [
    "continuity::",
    "execution::",
    "params::",
    "protocol::",
    "supervision::"
  ]) {
    assert(
      !openClawEventsSource.includes(dependency),
      `OpenClaw event projection must not depend on ${dependency}`
    );
  }
  for (const dependency of ["execution::", "io::", "supervision::", "transport::"]) {
    assert(
      !openClawProtocolSource.includes(dependency),
      `OpenClaw parser protocol must not depend on ${dependency}`
    );
  }
  // The package may not reach into the client it is composed by: its own
  // protocol vocabulary names the adapter SDK, the shared ACP vocabulary and its
  // own ports, and no client crate.
  assert(
    !openClawPackageSource.includes("licoup_native") &&
      !openClawPackageSource.includes("crate::platform") &&
      !openClawPackageSource.includes("crate::domain"),
    "the OpenClaw adapter package must reach no client crate for its protocol facts"
  );
  assert(
    !openClawDriverSource.includes("unsafe {") &&
      !reviewedRustUnsafeFiles.has(
        "crates/licoup-agent-openclaw/src/driver.rs"
      ),
    "OpenClaw driver must not retain unsafe or a stale unsafe ownership exemption"
  );

  // The facade the host used to hold is the package's own driver root now: it
  // names its leaves and re-exports the entries the composition reads.
  const piDriverFacadeSource = await readText(
    "crates/licoup-agent-pi/src/driver.rs"
  );
  const piDriverSource = await readJoinedText([
    // The wire half moved into the Pi adapter package: the parser, its protocol
    // state machine and the driver vocabulary the kernel facade names.
    "crates/licoup-agent-pi/src/parser.rs",
    ...(await collectSourceFiles("crates/licoup-agent-pi/src/parser", ".rs")),
    "crates/licoup-agent-pi/src/driver.rs",
    ...(await collectSourceFiles("crates/licoup-agent-pi/src/driver", ".rs"))
  ]);
  const piDriverFoundationSource = await readJoinedText([
    "crates/licoup-agent-pi/src/driver/errors.rs",
    "crates/licoup-agent-pi/src/driver/model.rs",
    "crates/licoup-agent-pi/src/driver/params.rs"
  ]);
  const piDriverSessionSource = await readText(
    "crates/licoup-agent-pi/src/driver/sessions.rs"
  );
  const piDriverSupervisionSource = await readText(
    "crates/licoup-agent-pi/src/driver/supervision.rs"
  );
  assert(
    !piDriverFacadeSource.includes("Command::new") &&
      !piDriverFacadeSource.includes("struct PiProtocol") &&
      !piDriverFacadeSource.includes("include!(") &&
      !piDriverFacadeSource.includes("#[path"),
    "Pi driver root must expose only ordinary modules and stable re-exports"
  );
  assert(
    piDriverSupervisionSource.includes(
      'LAUNCH_ARGS: &[&str] = &["--mode", "rpc", "--offline"]'
    ) &&
      piDriverSource.includes("BoundedStdinWriter") &&
      piDriverSource.includes("finish_protocol_transport") &&
      piDriverSource.includes("resolve_session_path_in_roots") &&
      piDriverSource.includes("sanitized_event") &&
      !piDriverSource.includes('Command::new("sh")') &&
      !piDriverSource.includes('Command::new("cmd")') &&
      !piDriverSource.includes('Command::new("powershell")'),
    "Pi driver split must retain fixed official RPC, exact-session, bounded-IO, and redacted-event boundaries"
  );
  for (const dependency of [
    "events::",
    "execution::",
    "io::",
    "probe::",
    "protocol::",
    "supervision::"
  ]) {
    assert(
      !piDriverFoundationSource.includes(dependency),
      `Pi result, error, and parameter foundations must not depend on ${dependency}`
    );
  }
  for (const dependency of ["execution::", "protocol::", "supervision::"]) {
    assert(
      !piDriverSessionSource.includes(dependency),
      `Pi exact-session resolver must not depend on ${dependency}`
    );
  }
  assert(
    !piDriverSource.includes("unsafe {") &&
      !reviewedRustUnsafeFiles.has(
        "crates/licoup-agent-pi/src/driver.rs"
      ),
    "Pi driver must not retain unsafe environment mutation or a stale unsafe ownership exemption"
  );

  const openCodeDriverFacadeSource = await readText(
    "crates/licoup-agent-opencode/src/driver.rs"
  );
  const openCodeServeTransportSource = await readText(
    "crates/licoup-agent-opencode/src/driver/serve_transport.rs"
  );
  const openCodeContinuitySource = await readText(
    "crates/licoup-agent-opencode/src/driver/continuity.rs"
  );
  const openCodeProbeSource = await readText(
    "crates/licoup-agent-opencode/src/driver/probe.rs"
  );
  assert(
    !openCodeDriverFacadeSource.includes("Command::new") &&
      !openCodeDriverFacadeSource.includes("struct AcpProtocol") &&
      !openCodeDriverFacadeSource.includes("include!(") &&
      !openCodeDriverFacadeSource.includes("#[path") &&
      openCodeDriverFacadeSource.includes("mod continuity;") &&
      openCodeDriverFacadeSource.includes("mod probe;") &&
      openCodeDriverFacadeSource.includes("mod serve_transport;") &&
      !openCodeDriverFacadeSource.includes("mod stdio_transport;") &&
      !openCodeDriverFacadeSource.includes("mod protocol;"),
    "OpenCode driver root must expose only ordinary modules and stable re-exports"
  );
  assert(
    openCodeServeTransportSource.includes("ensure_attachment") &&
      !openCodeServeTransportSource.includes("ensure_attach_endpoint") &&
      openCodeServeTransportSource.includes("watch_session_events") &&
      openCodeServeTransportSource.includes("open_serve_session") &&
      !openCodeServeTransportSource.includes("AcpProtocol") &&
      openCodeContinuitySource.includes("ProtocolConfig") &&
      openCodeContinuitySource.includes("open_serve_session") &&
      openCodeProbeSource.includes("ensure_attachment") &&
      !openCodeProbeSource.includes("ensure_attach_endpoint") &&
      openCodeProbeSource.includes("serve_capabilities") &&
      !openCodeServeTransportSource.includes("execute_acp") &&
      !openCodeProbeSource.includes("execute_acp"),
    "OpenCode must remain a serve-only adapter over the neutral ACP model without a retired stdio sibling"
  );

  // The control plane is owned by `licoup-agent-drivers`; the host reaches it
  // through the re-export at `platform::local_service`.
  const localServiceFacadeSource = await readText(
    "crates/licoup-agent-drivers/src/local_service.rs"
  );
  const localServiceFiles = await collectSourceFiles(
    "crates/licoup-agent-drivers/src/local_service",
    ".rs"
  );
  const localServiceProductionFiles = localServiceFiles.filter(
    (relativePath) => !relativePath.includes("/tests/")
  );
  const localServiceSource = await readJoinedText([
    "crates/licoup-agent-drivers/src/local_service.rs",
    ...localServiceProductionFiles
  ]);
  const localServiceHttpSource = await readText(
    "crates/licoup-agent-drivers/src/local_service/http.rs"
  );
  const localServiceSseSource = await readText(
    "crates/licoup-agent-drivers/src/local_service/sse.rs"
  );
  const localServiceServeSource = await readText(
    "crates/licoup-agent-drivers/src/local_service/serve.rs"
  );
  assert(
    !localServiceFacadeSource.includes("ureq::") &&
      !localServiceFacadeSource.includes("Command::new") &&
      !localServiceFacadeSource.includes("include!(") &&
      !localServiceFacadeSource.includes("#[path"),
    "Local service root must remain a thin target-neutral facade"
  );
  for (const targetToken of ["opencode_serve", "kilo_code_serve", "openclaw_gateway"]) {
    assert(
      !localServiceSource.includes(targetToken),
      `Local service foundation must not depend on target policy ${targetToken}`
    );
  }
  for (const jsonlToken of ["licoup_foundation::core::acp", "decode_json_line", "MAX_JSON_LINE_BYTES"]) {
    assert(
      !localServiceSource.includes(jsonlToken),
      `Local HTTP/SSE foundation must not absorb ACP JSONL ownership ${jsonlToken}`
    );
  }
  assert(
    localServiceHttpSource.includes("MAX_HTTP_RESPONSE_BODY_BYTES") &&
      localServiceHttpSource.includes("MAX_HTTP_HEADER_BYTES") &&
      localServiceHttpSource.includes("MAX_HTTP_IN_FLIGHT") &&
      localServiceSseSource.includes("MAX_SSE_LINE_BYTES") &&
      localServiceSseSource.includes("MAX_SSE_FRAME_BYTES") &&
      localServiceSseSource.includes("MAX_SSE_EVENTS_PER_STREAM") &&
      localServiceSseSource.includes("MAX_SSE_STREAMS") &&
      !localServiceSseSource.includes("read_line("),
    "Local HTTP and SSE must retain explicit body, header, line, frame, event, and concurrency bounds"
  );
  assert(
    !localServiceServeSource.includes("ServeEventParser") &&
      !localServiceServeSource.includes('"message.part.updated"') &&
      !localServiceServeSource.includes('"state": service_state') &&
      !localServiceServeSource.includes('"stateDir"'),
    "Local serve lifecycle must remain parser-neutral and never project raw local state"
  );

  return { localServiceSource };
}
