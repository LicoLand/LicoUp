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
    sourceLineCount,
  } = context;
  assert(
    reviewedRustUnsafeFiles instanceof Set,
    "runtime-driver checks require reviewedRustUnsafeFiles from crate-core stage",
  );
  const claudeCodeDriverFacadeSource = await readText(
    "crates/licoup-native/src/platform/claude_code_driver.rs"
  );
  const claudeCodeDriverFiles = await collectSourceFiles(
    "crates/licoup-native/src/platform/claude_code_driver",
    ".rs"
  );
  const claudeCodeDriverSource = await readJoinedText([
    "crates/licoup-native/src/platform/claude_code_driver.rs",
    ...claudeCodeDriverFiles
  ]);
  const claudeCodeFoundationSource = await readJoinedText([
    "crates/licoup-native/src/platform/claude_code_driver/errors.rs",
    "crates/licoup-native/src/platform/claude_code_driver/model.rs",
    "crates/licoup-native/src/platform/claude_code_driver/params.rs"
  ]);
  const claudeCodeCommandSource = await readText(
    "crates/licoup-native/src/platform/claude_code_driver/command.rs"
  );
  const claudeCodeEventsSource = await readText(
    "crates/licoup-native/src/platform/claude_code_driver/events.rs"
  );
  const claudeCodeProtocolSource = await readText(
    "crates/licoup-native/src/platform/claude_code_driver/protocol.rs"
  );
  const claudeCodeTransportSource = await readText(
    "crates/licoup-native/src/platform/claude_code_driver/transport.rs"
  );
  const claudeCodeSupervisionSource = await readText(
    "crates/licoup-native/src/platform/claude_code_driver/supervision.rs"
  );
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
      claudeCodeCommandSource.includes('"--no-session-persistence"') &&
      !claudeCodeCommandSource.includes('"--resume"') &&
      claudeCodeDriverSource.includes("MAX_POOLED_TRANSPORTS") &&
      claudeCodeDriverSource.includes("MAX_TRACKED_SESSIONS") &&
      claudeCodeDriverSource.includes("MAX_PROTOCOL_LINE_BYTES") &&
      claudeCodeDriverSource.includes("BoundedStdinWriter") &&
      claudeCodeDriverSource.includes("finish_protocol_transport") &&
      claudeCodeDriverSource.includes("project_event") &&
      !claudeCodeDriverSource.includes('Command::new("sh")') &&
      !claudeCodeDriverSource.includes('Command::new("cmd")') &&
      !claudeCodeDriverSource.includes('Command::new("powershell")'),
    "Claude Code split must retain fixed streaming input, exact live continuation, bounded IO, cleanup, and redacted events"
  );
  for (const dependency of [
    "command::",
    "control::",
    "events::",
    "execution::",
    "super::io::",
    "probe::",
    "protocol::",
    "supervision::",
    "transport::"
  ]) {
    assert(
      !claudeCodeFoundationSource.includes(dependency),
      `Claude Code result, error, and parameter foundations must not depend on ${dependency}`
    );
  }
  for (const dependency of ["execution::", "protocol::", "supervision::", "transport::"]) {
    assert(
      !claudeCodeCommandSource.includes(dependency),
      `Claude Code command identity must not depend on ${dependency}`
    );
  }
  for (const dependency of [
    "command::",
    "control::",
    "execution::",
    "io::",
    "params::",
    "protocol::",
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
  for (const dependency of ["events::", "execution::", "protocol::", "supervision::"]) {
    assert(
      !claudeCodeTransportSource.includes(dependency),
      `Claude Code transport lifecycle must not depend on ${dependency}`
    );
  }
  assert(
    claudeCodeSupervisionSource.includes("Arc::downgrade") &&
      !claudeCodeSupervisionSource.includes("TurnState") &&
      !claudeCodeSupervisionSource.includes("project_event"),
    "Claude Code live-session registry must remain independent of turn protocol and event projection"
  );
  assert(
    !claudeCodeDriverSource.includes("unsafe {") &&
      !reviewedRustUnsafeFiles.has(
        "crates/licoup-native/src/platform/claude_code_driver.rs"
      ),
    "Claude Code driver must not retain unsafe or a stale unsafe ownership exemption"
  );

  const openClawDriverFacadeSource = await readText(
    "crates/licoup-native/src/platform/openclaw_driver.rs"
  );
  const openClawDriverFiles = await collectSourceFiles(
    "crates/licoup-native/src/platform/openclaw_driver",
    ".rs"
  );
  const openClawDriverSource = await readJoinedText([
    "crates/licoup-native/src/platform/openclaw_driver.rs",
    ...openClawDriverFiles
  ]);
  const openClawFoundationSource = await readJoinedText([
    "crates/licoup-native/src/platform/openclaw_driver/errors.rs",
    "crates/licoup-native/src/platform/openclaw_driver/model.rs",
    "crates/licoup-native/src/platform/openclaw_driver/params.rs"
  ]);
  const openClawContinuitySource = await readText(
    "crates/licoup-native/src/platform/openclaw_driver/continuity.rs"
  );
  const openClawEventsSource = await readText(
    "crates/licoup-native/src/platform/openclaw_driver/events.rs"
  );
  const openClawSupervisionSource = await readText(
    "crates/licoup-native/src/platform/openclaw_driver/supervision.rs"
  );
  const openClawProbeSource = await readText(
    "crates/licoup-native/src/platform/openclaw_driver/probe.rs"
  );
  assert(
    !openClawDriverFacadeSource.includes("Command::new") &&
      !openClawDriverFacadeSource.includes("struct OpenClawProtocol") &&
      !openClawDriverFacadeSource.includes("include!(") &&
      !openClawDriverFacadeSource.includes("#[path"),
    "OpenClaw driver root must expose only ordinary modules and stable re-exports"
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
      openClawDriverSource.includes("projected_event") &&
      !openClawDriverSource.includes("update.payload().clone()") &&
      !openClawDriverSource.includes('Command::new("sh")') &&
      !openClawDriverSource.includes('Command::new("cmd")') &&
      !openClawDriverSource.includes('Command::new("powershell")'),
    "OpenClaw split must retain fixed Gateway ACP, exact continuity, bounded IO, and redacted event boundaries"
  );
  for (const dependency of [
    "continuity::",
    "events::",
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
  assert(
    !openClawDriverSource.includes("unsafe {") &&
      !reviewedRustUnsafeFiles.has(
        "crates/licoup-native/src/platform/openclaw_driver.rs"
      ),
    "OpenClaw driver must not retain unsafe or a stale unsafe ownership exemption"
  );

  const piDriverFacadeSource = await readText(
    "crates/licoup-native/src/platform/pi_driver.rs"
  );
  const piDriverFiles = await collectSourceFiles(
    "crates/licoup-native/src/platform/pi_driver",
    ".rs"
  );
  const piDriverSource = await readJoinedText([
    "crates/licoup-native/src/platform/pi_driver.rs",
    ...piDriverFiles
  ]);
  const piDriverFoundationSource = await readJoinedText([
    "crates/licoup-native/src/platform/pi_driver/errors.rs",
    "crates/licoup-native/src/platform/pi_driver/model.rs",
    "crates/licoup-native/src/platform/pi_driver/params.rs"
  ]);
  const piDriverSessionSource = await readText(
    "crates/licoup-native/src/platform/pi_driver/sessions.rs"
  );
  const piDriverSupervisionSource = await readText(
    "crates/licoup-native/src/platform/pi_driver/supervision.rs"
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
        "crates/licoup-native/src/platform/pi_driver.rs"
      ),
    "Pi driver must not retain unsafe environment mutation or a stale unsafe ownership exemption"
  );

  const openCodeDriverFacadeSource = await readText(
    "crates/licoup-native/src/platform/opencode_driver.rs"
  );
  const openCodeServeTransportSource = await readText(
    "crates/licoup-native/src/platform/opencode_driver/serve_transport.rs"
  );
  const openCodeContinuitySource = await readText(
    "crates/licoup-native/src/platform/opencode_driver/continuity.rs"
  );
  const openCodeProbeSource = await readText(
    "crates/licoup-native/src/platform/opencode_driver/probe.rs"
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
    openCodeServeTransportSource.includes("ensure_attach_endpoint") &&
      openCodeServeTransportSource.includes("watch_session_events") &&
      openCodeServeTransportSource.includes("open_serve_session") &&
      !openCodeServeTransportSource.includes("AcpProtocol") &&
      openCodeContinuitySource.includes("ProtocolConfig") &&
      openCodeContinuitySource.includes("open_serve_session") &&
      openCodeProbeSource.includes("ensure_attach_endpoint") &&
      openCodeProbeSource.includes("serve_capabilities") &&
      !openCodeServeTransportSource.includes("execute_acp") &&
      !openCodeProbeSource.includes("execute_acp"),
    "OpenCode must remain a serve-only adapter over the neutral ACP model without a retired stdio sibling"
  );

  const localServiceFacadeSource = await readText(
    "crates/licoup-native/src/platform/local_service.rs"
  );
  const localServiceFiles = await collectSourceFiles(
    "crates/licoup-native/src/platform/local_service",
    ".rs"
  );
  const localServiceProductionFiles = localServiceFiles.filter(
    (relativePath) => !relativePath.includes("/tests/")
  );
  const localServiceSource = await readJoinedText([
    "crates/licoup-native/src/platform/local_service.rs",
    ...localServiceProductionFiles
  ]);
  const localServiceHttpSource = await readText(
    "crates/licoup-native/src/platform/local_service/http.rs"
  );
  const localServiceSseSource = await readText(
    "crates/licoup-native/src/platform/local_service/sse.rs"
  );
  const localServiceServeSource = await readText(
    "crates/licoup-native/src/platform/local_service/serve.rs"
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
  for (const jsonlToken of ["crate::core::acp", "decode_json_line", "MAX_JSON_LINE_BYTES"]) {
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
    localServiceServeSource.includes("event_session != session_id") &&
      localServiceServeSource.includes('"message.part.updated" | "message.part.delta"') &&
      !localServiceServeSource.includes('"state": service_state') &&
      !localServiceServeSource.includes('"stateDir"'),
    "Local serve lifecycle must require exact-session events and never project raw local state"
  );

  return { localServiceSource };
}
