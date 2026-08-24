export async function checkTargetServeAndGateway(context, { localServiceSource }) {
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
  const openCodeServeFacadeSource = await readText(
    "crates/licoup-native/src/platform/opencode_serve.rs"
  );
  const openCodeServePolicySource = await readText(
    "crates/licoup-native/src/platform/opencode_serve/policy.rs"
  );
  const openCodeParserSource = await readText(
    "crates/licoup-native/src/platform/native_agent_parser/adapters/opencode.rs"
  );
  const kiloCodeServeFacadeSource = await readText(
    "crates/licoup-native/src/platform/kilo_code_serve.rs"
  );
  const kiloCodeServePolicySource = await readText(
    "crates/licoup-native/src/platform/kilo_code_serve/policy.rs"
  );
  const kiloCodeParserSource = await readText(
    "crates/licoup-native/src/platform/native_agent_parser/adapters/kilo_code.rs"
  );
  for (const [target, facade, policy, parser, foreignPolicy] of [
    [
      "OpenCode",
      openCodeServeFacadeSource,
      openCodeServePolicySource,
      openCodeParserSource,
      "kilo_code"
    ],
    [
      "Kilo Code",
      kiloCodeServeFacadeSource,
      kiloCodeServePolicySource,
      kiloCodeParserSource,
      "opencode"
    ]
  ]) {
    assert(
      facade.includes("local_service::serve::ensure") &&
        facade.includes("local_service::sse::watch_data") &&
        facade.includes("ServeEventParser") &&
        facade.includes("EventStreamFailure") &&
        !facade.includes("ureq::") &&
        !facade.includes("TcpListener") &&
        !facade.includes("Command::new") &&
        !facade.includes("read_state"),
      `${target} serve root must retain bounded transport and its parser-owned event ingress`
    );
    assert(
      parser.includes("struct ServeEventParser") &&
        parser.includes('event_type != "message.part.updated"') &&
        parser.includes("session_id(properties) != Some(self.session_id.as_str())") &&
        parser.includes('Some("assistant")') &&
        parser.includes("assistant_messages") &&
        !parser.includes('"state": service_state') &&
        !parser.includes('"stateDir"'),
      `${target} parser must require exact-session assistant events and never project raw local state`
    );
    assert(
      !policy.includes(foreignPolicy) &&
        !policy.includes("local_service::http") &&
        !policy.includes("local_service::sse"),
      `${target} policy must not depend on another target or transport implementation`
    );
  }

  const openClawGatewayFacadeSource = await readText(
    "crates/licoup-native/src/platform/openclaw_gateway.rs"
  );
  const openClawGatewayFiles = await collectSourceFiles(
    "crates/licoup-native/src/platform/openclaw_gateway",
    ".rs"
  );
  const openClawGatewayProductionFiles = openClawGatewayFiles.filter(
    (relativePath) => !relativePath.includes("/tests/")
  );
  const openClawGatewaySource = await readJoinedText([
    "crates/licoup-native/src/platform/openclaw_gateway.rs",
    ...openClawGatewayProductionFiles
  ]);
  const openClawGatewayCommandSource = await readText(
    "crates/licoup-native/src/platform/openclaw_gateway/command.rs"
  );
  const openClawGatewayHealthSource = await readText(
    "crates/licoup-native/src/platform/openclaw_gateway/health.rs"
  );
  const openClawGatewayLifecycleSource = await readText(
    "crates/licoup-native/src/platform/openclaw_gateway/lifecycle.rs"
  );
  assert(
    !openClawGatewayFacadeSource.includes("Command::new") &&
      !openClawGatewayFacadeSource.includes("ureq::") &&
      !openClawGatewayFacadeSource.includes("include!(") &&
      !openClawGatewayFacadeSource.includes("#[path"),
    "OpenClaw Gateway root must remain a thin dedicated facade"
  );
  assert(
    openClawGatewayCommandSource.includes("process::spawn_detached") &&
      openClawGatewayHealthSource.includes("http::probe_status") &&
      openClawGatewayLifecycleSource.includes("port::select") &&
      openClawGatewayLifecycleSource.includes("state::write_json") &&
      openClawGatewayLifecycleSource.includes("process::stop") &&
      !openClawGatewaySource.includes("local_service::serve") &&
      !openClawGatewaySource.includes("local_service::sse") &&
      !openClawGatewaySource.includes("ureq::"),
    "OpenClaw Gateway may reuse only low-level local process, port, state, and bounded HTTP primitives"
  );
  assert(
    openClawGatewayHealthSource.includes('"attachMode": "vendor-default"') &&
      openClawGatewayLifecycleSource.includes('"stoppedOwnedProcess": false') &&
      openClawGatewaySource.includes("wsUrl") &&
      !openClawGatewayLifecycleSource.includes('"state": service_state') &&
      !openClawGatewayLifecycleSource.includes('"stateDir"'),
    "OpenClaw Gateway must retain vendor attach, WebSocket, owned-stop, and redacted status semantics"
  );
  assert(
    !localServiceSource.includes("unsafe {") &&
      !openCodeServeFacadeSource.includes("unsafe {") &&
      !kiloCodeServeFacadeSource.includes("unsafe {") &&
      !openClawGatewaySource.includes("unsafe {"),
    "Local service and target adapters must not introduce unsafe blocks"
  );

}
