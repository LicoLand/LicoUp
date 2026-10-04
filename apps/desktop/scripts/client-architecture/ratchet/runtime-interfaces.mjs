/**
 * Reviewed runtime-selected process interfaces, not permissions or exclusions.
 * Exact source digests intentionally require review after source changes.
 * New sites never inherit a neighbouring record or a file-level tool mention.
 */
const N = "crates/licoup-native/src/";
const DR = "crates/licoup-agent-drivers/src/";
const F = "crates/licoup-foundation/src/";
const T = "crates/licoup-agent-targets/src/";
const D = "apps/desktop/lib/src/platform/native_client/";
const SUPERVISOR = `${F}platform/process_supervisor.rs`;
const MIGRATE_CONVERTER = "crates/licoup-migrate/src/converter_process.rs";
const PARAMETERS = `${T}domain/targets/parameters.rs`;
const BINARIES = `${T}domain/targets/binaries.rs`;
const SHELL = `${T}platform/user_shell_environment.rs`;
const SCRIPT = `${N}domain/client_update/native_runner/script.rs`;
const PLAN = `${N}domain/client_update/native_runner/plan.rs`;
const APPLY = `${N}domain/client_update/native_runner/mod.rs`;

// These are reviewed source facts, deliberately not refreshed by measurement.
const SOURCES = Object.freeze({
  [D + "native_cli_runtime_context.dart"]: "122f710193c31b53eb152b95cb7960b51f67208a3c6e7f96ae63e2d0bd89c405",
  [D + "native_one_shot_command_executor.dart"]: "a9aceae0873a4603bae360eb9a08f81449078074a80602c2672f3ddd76b41045",
  "crates/licoup-mcp/src/application.rs": "b55110ba2db3ac10d493f151dbb5ee76a85ae1a9aa498f8da1caff777643f061",
  [N + "domain/agent_hub/argv.rs"]: "4f942a0f7df3f2e2e8396a40906381811ae6dcd656c2a7bcf9d7ceb5c214d911",
  [N + "domain/agent_hub/version_check.rs"]: "fd0b8afba2b39f844a4a232af074954e452e8eae60ca49ba979ffe7b6e23970b",
  [N + "domain/agent_usage/agent_usage_native/deepseek.rs"]: "c317130155bec59b96525b71e5a6fa763e7d3aa2a38062ed5846fba49b3e1fb5",
  [N + "domain/agent_usage/agent_usage_native/openclaw.rs"]: "b1f9a6a2b74b7477e24d0fea2b1a3c9d658a2a66542af5676b2537cfb6b49a52",
  [APPLY]: "07491d6d0ff170596be9ed55f3b6ca558422f7e141cd9f2445fc7211346f0071",
  [PLAN]: "473f8f8716db2a35b7af98ac649cf82093f61a857ddceb1870e0c5a842b6e635",
  [SCRIPT]: "f9e10ec9f18c4a4ad29d7dbebdcfa832c5b5f65e7ad33ec6d6732c08334d1d82",
  [N + "domain/client_update/native_runner/spawn.rs"]: "b93a68f67017eb7e2b7c866dbe78637d6fbeffb8b748f42d00922a1972ffc987",
  [N + "domain/collaboration_plugin/assembly/runtime/runner.rs"]: "2aabbdd6feec68f0ebc4424bc88f295ea336e2838b4dc10ffe766e2e437ad9c5",
  [N + "domain/provider_quota/antigravity.rs"]: "5b275717c421a7cd2218b3395cab7a0bee6c053863dd53eb516ebb555ac24f82",
  [N + "domain/provider_quota/codex.rs"]: "8dc13c83b0f4bb333b4de063845a2d7561f9d07434ec94a0257eb8c5d093cbd5",
  [BINARIES]: "7c71b58d968831ac48e6200130e04b542d6c163392f5f0b9e49ebb95d4798872",
  [T + "domain/targets/model_catalog/antigravity.rs"]: "c18e9624e37d563cebb74c71cceef0a6495d40e0df39025998557f9c11fc3308",
  [T + "domain/targets/model_catalog/cursor.rs"]: "cc30dc2803e20c9fe938faf58ea5b49caf319eb83492f7096a631b570b7f6464",
  [T + "domain/targets/model_catalog/deepseek.rs"]: "ad8de7ce729f12bf3ca6bc78864e258a2412bf54db3a15c70e193e23be0183be",
  [T + "domain/targets/model_catalog/kilo.rs"]: "1945c633ad10cb99c2dc62e063e2778c8d7930eee17d7eeedb9c75eabc531dfe",
  [T + "domain/targets/model_catalog/opencode.rs"]: "e20e6e35d4e13d55f3359c3356b9f480a13a8a7f80249dd035fdf2b62e96ac20",
  [T + "domain/targets/model_catalog/pi.rs"]: "22466bce8b6d17b8125cbcb036ccd549e64867b56fdbf3883589610f0dcc3f2e",
  [PARAMETERS]: "43cdd22e2653747415a63b54cf508b35b8250d77b12c914c69925cc8f398bf8b",
  [T + "domain/targets/virtual_machine_discovery.rs"]: "c2132da0c5a99e8f913a16c79e0e836510e831fc2a83970e8904da7dc0fca89e",
  [DR + "acp_driver_runtime/supervision.rs"]: "7300984d196c6a73ba67e82b6a96c8c90e41b8540f7b03e7e6a7a7968c31705b",
  [DR + "acp_session_transport/command.rs"]: "b16fc8b4383c2b27693417d311200d15fefd047c8929be51d9bf98dc6305da9d",
  [DR + "local_service/process.rs"]: "40c1858f9ddf63679d771bb3f38ec4401ce7e75aa957ff29488ab3154117b9d9",
  [N + "platform/antigravity_driver/auth.rs"]: "cf7f6d1607aef2f200b2cb075d5f05a99ff482555ef57d7d77ce6a8c54621bfa",
  [N + "platform/antigravity_driver/execution.rs"]: "646d01cfd0c377272d4c51a368a7777fd004583682e368e3cb380af7127a4c69",
  [N + "platform/antigravity_driver/probe.rs"]: "75c62a13bccda44854d39b98ba41eaf2a146f2e0f64fed7b98edfc7e8b9972ae",
  [N + "platform/claude_code_driver/command.rs"]: "d5261fa6577d9ddae24027b1b58a165d239fe3122b7b648cae50256c9ee65d6d",
  [N + "platform/claude_code_driver/probe.rs"]: "490b5c591d9d65a1714116d75198cb93b604be1b11ad5cf29f333291a14b8c29",
  [N + "platform/codex_app_server/launch.rs"]: "20ee62c1c353f0107257c723e1f3bd6a61128aa3439c2245300569b5d98c65ef",
  [N + "platform/codex_plugin_manager.rs"]: "58aa902449d5a9f25b342f4541ed6c56488af6c0c23c633892cce24bbea31855",
  [N + "platform/cursor_driver/execution.rs"]: "e50f484719e8828fb7842711337d8886d6b220986fced0d2757fedbe6038576f",
  [N + "platform/cursor_driver/probe.rs"]: "e5fb151d35ada8ac16770cfa444a46edc9b07dfbfd02b36f165c0947b3f69c77",
  [N + "platform/deepseek_harness_driver.rs"]: "4069c51e24d5e58698f37034eb3685ce6a235be2f8eb72b999c681942dc6094d",
  [N + "platform/extension_host/isolation/confinement.rs"]: "2cc72396a086eea81f47ce7fabe818dd4b5f2c054d3280e06c45cd8ac8046956",
  [N + "platform/generic_cli_driver.rs"]: "6970fd309539bbfa2d5b4fbd7191cb292b86b5b1a3f1ebdde8b184c7747c6341",
  [N + "platform/hermes_driver/probe.rs"]: "973dddadc2653371f6c19a21a3987a19fa62aae3edb2694994bd7abf4e242d23",
  [N + "platform/lico_agent_driver/execution.rs"]: "061e3f118a7eb9944e328ea3cf2e61ab2845541f3dc88d5b850dc12c7063de55",
  [N + "platform/lico_agent_driver/probe.rs"]: "b968dbfd55ec7e1ca7c83aa5d5fedfc244c6b554d8fe96a441923fa22e0d3179",
  [N + "platform/local_service/process.rs"]: "ab1a749eeffbdca47267a6c888882e033eb2c647da48a0beef7fa79399e38adc",
  [MIGRATE_CONVERTER]: "1a468623ec8a3a0d23371c0dad7fdfdcb145f5cd6886cb306776c6f3acc59277",
  [N + "platform/mcp_service_process.rs"]: "2489fdf68618b2aeb3e803114636017898ff2e805aa0d947e693085599a204e9",
  [N + "platform/local_service/process.rs"]: "ab1a749eeffbdca47267a6c888882e033eb2c647da48a0beef7fa79399e38adc",
  [N + "platform/mcp_service_process.rs"]: "2489fdf68618b2aeb3e803114636017898ff2e805aa0d947e693085599a204e9",
  [N + "platform/openclaw_driver/probe.rs"]: "49a1e80055550a28d5de652f4236dfbf3c99ba53ea53c86692b44810f0d23862",
  [N + "platform/openclaw_driver/supervision.rs"]: "c41128bbbaf81904d6c263ea97988ea1265dd74fa30d8867be73cdce134079bd",
  [N + "platform/openclaw_gateway/command.rs"]: "5b747fa62fa6cd21074aa05990cf195377eeafed75907262598c40a1ac842601",
  [N + "platform/pi_driver/probe.rs"]: "da5671f51a42b93020a87497945d7d0521957d8c4dbae7f68a2d99f2d0630939",
  [N + "platform/pi_driver/supervision.rs"]: "eb35a662553bb9a7292d38c1bd6537eb11cbccc77205325cb8029219da58aafe",
  [N + "platform/process_sandbox/seatbelt.rs"]: "33208cec6c4bd28e1b60ebb4e74c43921bf3df114fe438d05893144868686367",
  [N + "platform/process_sandbox/strategy.rs"]: "a8832eb3055c1dd7fde3e99c413aa92ec8c6e98a51a89345d4b377b8440d66f4",
  [SUPERVISOR]: "cc54d42dbc06636b95f686587c05bea047396d0652d1561a1abe6c99d7fff700",
  [N + "platform/strategy_runtime/mod.rs"]: "45551821627cd476374c37ead3bde26b0f2ca4df217496aa96dccbdeebf67443",
  [SHELL]: "e2a192a409575acf91555b56912d83d62f8b004904f56014b21024e8585a23a7",
});

function entries(file, selection, sites, extra = []) {
  const selectionFile = selection.file ?? file;
  const files = [...new Set([file, selectionFile, ...extra])];
  const provenance = files.map((source) => Object.freeze({file: source, digest: SOURCES[source],
    role: source === SCRIPT ? "materialized-script-template" : "reviewed-interface-source-and-provenance"}));
  return sites.map(([sink, purpose]) => Object.freeze({id: `${file}::${sink}`, purpose,
    selection: Object.freeze({...selection, file: selectionFile}), provenance}));
}

const parameter = (evidence) => ({kind: "parameter", evidence});
const field = (evidence) => ({kind: "field", evidence});
const command = {kind: "command", file: SUPERVISOR, evidence: "command: &mut Command"};
const configuration = {kind: "configuration", file: PARAMETERS, symbol: "param_string", evidence: "fn param_string(params: &Value, key: &str)"};

export const RUNTIME_INTERFACE_REVIEWS = Object.freeze([
  ...entries(D + "native_cli_runtime_context.dart", parameter("String executable,"), [
    ["ee1df33749dc", "Start the resolved native CLI through the injected executable/environment port; the candidate resolver excludes the GUI executable to avoid recursive client launches."],
    ["e76e4e09cac0", "Start a caller-selected native CLI executable in an explicit non-normal process mode; this remains the same environment-bound platform process interface."],
  ]),
  ...entries(D + "native_one_shot_command_executor.dart", parameter("String executable,"), [
    ["24892bcbafb7", "Run one native command through the injected executable port, using resolved licoup-cli or its PATH fallback rather than assuming a literal installation path."],
  ], [D + "native_cli_runtime_context.dart"]),
  ...entries("crates/licoup-mcp/src/application.rs", {kind: "environment", evidence: 'std::env::var_os("LICOUP_CLI_BINARY")'}, [
    ["df6167de50f6", "The independent MCP process starts its owning CLI from the host-provided LICOUP_CLI_BINARY binding for rpc stdio; this is a native bridge, not permission to run an arbitrary remote command."],
  ], [N + "platform/mcp_service_process.rs"]),
  ...entries(N + "domain/agent_hub/argv.rs", parameter("program: &str"), [
    ["db471ee64ae2", "Agent Hub lifecycle execution accepts a validated program/argv pair from the selected vendor installation channel; package-manager use is visible here, not hidden as a native client prerequisite."],
  ]),
  ...entries(N + "domain/agent_hub/version_check.rs", parameter("program: &Path"), [
    ["599a57a1fc1d", "Probe the installed Agent's supplied executable binding with a bounded version command; available installation paths and wrapper identities are runtime data."],
  ]),
  ...entries(N + "domain/agent_usage/agent_usage_native/deepseek.rs", {kind: "discovery", file: BINARIES, symbol: "find_binary", evidence: "fn find_binary(names: &[&str])"}, [
    ["aa789fdbbd01", "DeepSeek Harness usage reads run the installed Agent's PATH-discovered Node runtime against the source-owned READER program after the discovered-agent execution gate; Node is an explicit external runtime dependency at this interface."],
  ], [SHELL]),
  ...entries(N + "domain/agent_usage/agent_usage_native/openclaw.rs", parameter("fn query_gateway_once(executable: &Path"), [
    ["360f213083b9", "Query OpenClaw usage.cost through the locally advertised runtime executable passed from the discovery result callback; no remote request chooses the local binary path."],
  ]),
  ...entries(N + "domain/agent_usage/agent_usage_native/openclaw.rs", command, [
    ["a4916c466b33", "Capture the prepared OpenClaw usage.cost command with the bounded supervisor after applying the user-shell environment; executable identity remains caller-prepared state."],
  ]),
  ...entries(N + "domain/client_update/native_runner/spawn.rs", {kind: "materialized-script", evidence: "plan.script_path"}, [
    ["92782c71fad8", "Construct the Unix interpreter boundary for the source-owned update script materialized at an apply-plan path; template and argument guards are pinned, without granting installation or signing authority."],
    ["b330e9198180", "Spawn the Unix apply-plan script through the prepared OS interpreter; script provenance stays visible and this record does not certify deployment prerequisites or live update acceptance."],
    ["0156123e5ff6", "Construct the Windows PowerShell boundary for the source-owned materialized update script, retaining its template and guarded positional-argument provenance."],
    ["b330e9198180#2", "Spawn the Windows apply-plan script with its reviewed interpreter and template; this source classification does not authorize an actual client replacement or launch."],
  ], [PLAN, SCRIPT, APPLY]),
  ...entries(N + "domain/collaboration_plugin/assembly/runtime/runner.rs", {kind: "command", evidence: "command: Command,"}, [
    ["62d7f9b48bbe", "Spawn the validated local assembly's prepared Command from its selected runner and sandbox preparation; the implementation owns process identity capture and cleanup if adoption fails."],
  ]),
  ...entries(N + "domain/provider_quota/antigravity.rs", command, [
    ["4c12ae154e53", "Capture the Antigravity quota discovery helper's prepared platform command under time/output bounds; its argv-head selection is part of the owner protocol rather than an inferred file-level tool name."],
  ]),
  ...entries(N + "domain/provider_quota/codex.rs", parameter("executable: &Path"), [
    ["c25730361e38", "Query Codex app-server rate limits through the injected executable callback and one bounded stdio exchange; binary identity comes from the local runtime binding, not response contents."],
  ]),
  ...entries(T + "domain/targets/model_catalog/antigravity.rs", configuration, [
    ["ebfec92bd3a8", "Construct the selected Antigravity model query from explicit JSON path options or local discovery; the user-selected Agent and execution gate are retained without constraining those configured paths for measurement."],
  ], [BINARIES, SHELL]),
  ...entries(T + "domain/targets/model_catalog/antigravity.rs", command, [
    ["2aae20787da1", "Capture the selected Antigravity models command after user-shell environment preparation with the existing timeout/output bounds."],
  ], [PARAMETERS, BINARIES]),
  ...entries(T + "domain/targets/model_catalog/cursor.rs", configuration, [
    ["70e42a6bb7bb", "Construct Cursor's selected-agent model query from explicit CLI path options or discovery, preserving the discovered-agent execution gate and terminal-equivalent environment."],
  ], [BINARIES, SHELL]),
  ...entries(T + "domain/targets/model_catalog/cursor.rs", command, [
    ["3f179eee8ffb", "Capture the prepared Cursor model-catalog command under the source-owned bounded runner; its configured executable is not replaced with a fixed name to satisfy measurement."],
  ], [PARAMETERS, BINARIES]),
  ...entries(T + "domain/targets/model_catalog/deepseek.rs", configuration, [
    ["163f4356c3db", "Construct the DeepSeek metadata reader from a configured or PATH-discovered Node runtime and selected dsh binding; both executable gates and the fixed METADATA_PROBE remain source-owned."],
    ["1754e96dd539", "Run the prepared DeepSeek metadata reader through the scrubbed untrusted-Agent capture interface; the explicit Node dependency and selected Agent binding remain visible."],
  ], [BINARIES, SHELL, SUPERVISOR]),
  ...entries(T + "domain/targets/model_catalog/kilo.rs", configuration, [
    ["76eaaa43aad7", "Construct the selected Kilo models query using caller path settings and discovery fallback; provider availability is observed in the user's shell environment, not assumed from a literal command name."],
  ], [BINARIES, SHELL]),
  ...entries(T + "domain/targets/model_catalog/kilo.rs", command, [
    ["aa8553b13d86", "Capture the caller-prepared Kilo models command with bounded output and duration after environment preparation."],
  ], [PARAMETERS, BINARIES]),
  ...entries(T + "domain/targets/model_catalog/opencode.rs", configuration, [
    ["dd0f86dfece5", "Construct the OpenCode model query from configured CLI paths or discovery; the subsequent untrusted-Agent runner deliberately overrides inherited environment with its scrubbed contract."],
  ], [BINARIES, SHELL]),
  ...entries(T + "domain/targets/model_catalog/opencode.rs", command, [
    ["81917d89ce43", "Capture the prepared OpenCode catalog command through the untrusted-Agent supervisor, preserving its restricted environment and output/time limits."],
  ], [PARAMETERS, BINARIES]),
  ...entries(T + "domain/targets/model_catalog/pi.rs", configuration, [
    ["5b27ff08b97d", "Construct Pi's list-models request from piCliPath or local discovery after the execution gate; configured installation paths remain an intentional runtime input."],
  ], [BINARIES, SHELL]),
  ...entries(T + "domain/targets/model_catalog/pi.rs", command, [
    ["1e1d9ae5982a", "Capture the selected Pi model query through the scrubbed untrusted-Agent runner; this classification does not execute the Agent or certify its live response."],
  ], [PARAMETERS, BINARIES]),
  ...entries(T + "domain/targets/virtual_machine_discovery.rs", field("Command::new(&self.orb)"), [
    ["ff50f785c7de", "List running OrbStack machines using the selected local orb executable; listing is distinct from guest execution and is not attributed to Python merely because another function contains a Python probe."],
    ["ff50f785c7de#2", "Run the fixed guest discovery script through the selected OrbStack executable and machine binding; the guest script and delegated runtime purpose remain visible in this source-bound interface."],
  ]),
  ...entries(T + "domain/targets/virtual_machine_discovery.rs", command, [
    ["d312c2e7bc93", "Capture prepared OrbStack listing/probe commands under the explicit machine/probe bounds; source review distinguishes their different purposes instead of guessing from file-wide names."],
  ]),
  ...entries(DR + "acp_driver_runtime/supervision.rs", field("Command::new(&self.executable)"), [
    ["a01ddab5f5c3", "Launch the registered ACP driver's configured executable with its launch arguments, workspace and reasoning environment through the supervised process interface."],
  ]),
  ...entries(DR + "acp_session_transport/command.rs", field("Command::new(&self.executable)"), [
    ["8badc004c930", "Launch the local executable branch of ACP session transport when no external runtime connection supplies the command; keep the configured executable boundary explicit."],
  ]),
  ...entries(N + "platform/antigravity_driver/auth.rs", parameter("executable: Option<&str>"), [
    ["439bc3ba329a", "Construct the Antigravity OAuth-start command using an optional selected executable and vendor default; this source review does not grant or verify consent for that external authorization effect."],
  ]),
  ...entries(N + "platform/antigravity_driver/auth.rs", parameter("fn probe_authorization(executable: &str)"), [
    ["439bc3ba329a#2", "Construct the selected Antigravity models-based authorization probe before a turn, keeping the separate consent boundary for actually starting OAuth."],
  ]),
  ...entries(N + "platform/antigravity_driver/execution.rs", parameter("executable: &str"), [
    ["f0312bc5c0c1", "Launch an Antigravity turn through the caller-selected executable with admitted configuration and scoped Membership/MCP context; runtime selection remains unconstrained by the metric."],
  ]),
  ...entries(N + "platform/antigravity_driver/probe.rs", parameter("executable: &str"), [
    ["de42112b0028", "Construct the bounded Antigravity version/help capability probe around the executable supplied by its driver, with untrusted-Agent environment preparation."],
  ]),
  ...entries(N + "platform/claude_code_driver/command.rs", field("Command::new(&self.executable)"), [
    ["22e72e5babe5", "Launch the configured Claude Code process with source-owned arguments and workspace, retaining the executable-directory PATH head needed by sibling vendor tools."],
  ]),
  ...entries(N + "platform/claude_code_driver/probe.rs", parameter("executable: &str"), [
    ["c6034ed13778", "Construct Claude Code's bounded capability probe from its caller-selected executable; the source supervisor and untrusted environment remain separate runtime guarantees."],
  ]),
  ...entries(N + "platform/codex_app_server/launch.rs", field("Command::new(&self.executable)"), [
    ["8bed3b547011", "Launch the configured Codex app-server command with stdio and scoped launch environment; Membership and MCP root binding are not inferred from a fixed executable spelling."],
  ]),
  ...entries(N + "platform/codex_plugin_manager.rs", {kind: "discovery", evidence: "fs::canonicalize(path)"}, [
    ["d588a28cbc65", "Query the exact managed Codex plugin using a canonicalized caller-selected Codex executable; filesystem identity is verified by the owner rather than treated as a source literal."],
  ]),
  ...entries(N + "platform/codex_plugin_manager.rs", command, [
    ["350edd5414cf", "Capture the prepared Codex plugin-status command with bounded output; raw plugin inventory remains inside its source owner."],
    ["dab0f898128f", "Capture a Codex plugin lifecycle command using the prepared executable and argv, without interpreting a runtime-selected binary as a literal tool name or granting the lifecycle effect."],
    ["dab0f898128f#2", "Capture a Codex plugin lifecycle JSON command under the same selected-executable and bounded-output contract; this is distinct from the non-JSON invocation."],
  ]),
  ...entries(N + "platform/codex_plugin_manager.rs", parameter("executable: &Path"), [
    ["785fe394d370", "Construct a Codex plugin lifecycle invocation from its prepared runtime executable and caller-provided arguments; this review does not authorize installation effects."],
    ["785fe394d370#2", "Construct the JSON-returning Codex plugin lifecycle invocation from the same explicit runtime binding while retaining a separate execution-site identity."],
  ]),
  ...entries(N + "platform/cursor_driver/execution.rs", parameter("executable: &str"), [
    ["526a5bc1f041", "Create a Cursor chat session using the selected Agent executable and bounded workspace, with the same scoped caller context as the resumed turn."],
    ["526a5bc1f041#2", "Execute the resumed Cursor turn using the selected executable, explicit workspace/session arguments and supervised transport; it is not the chat-creation invocation."],
  ]),
  ...entries(N + "platform/cursor_driver/probe.rs", parameter("executable: &str"), [
    ["aea70b7b1ea4", "Construct the bounded Cursor capability probe from the driver-supplied executable, preserving its environment isolation and output handling."],
  ]),
  ...entries(N + "platform/deepseek_harness_driver.rs", field("Command::new(&config.executable)"), [
    ["0988ff707b77", "Start the configured DeepSeek Harness SDK-profile JSON-RPC carrier under its workspace and supervised stdio; this is an Agent runtime binding, not a fixed native artifact."],
  ]),
  ...entries(N + "platform/extension_host/isolation/confinement.rs", field("Command::new(&program.executable)"), [
    ["f01e7857fd11", "Start one extension instance's validated program in trusted local mode through the executable and arguments the confinement plan admitted before any process exists; the plan canonicalizes that path, so the executable stays intentional runtime state rather than a fixed native artifact, and this record grants no confinement."],
  ]),
  ...entries(N + "platform/extension_host/isolation/confinement.rs", field('Command::new("/usr/bin/sandbox-exec")'), [
    ["efc45e369a5f", "Construct the macOS seatbelt boundary for a restricted instance around the same admitted program: the source trust check accepts only a root-owned, non-symlink /usr/bin/sandbox-exec, and the admitted executable follows the generated profile as its guest target; the profile, not this record, decides the filesystem, network and process-fork scope."],
  ]),
  ...entries(N + "platform/generic_cli_driver.rs", parameter("executable: &str"), [
    ["9ebc382eb9d5", "Execute a registered argv-only Agent through the caller-selected executable, argument substitution and chosen PTY/stdio mode; arbitrary legitimate Agent paths are not constrained to manufacture a baseline."],
  ]),
  ...entries(N + "platform/hermes_driver/probe.rs", parameter("executable: &str"), [
    ["afeccfaac7ad", "Construct the bounded Hermes capability probe from its runtime executable binding; external Agent interpreter requirements remain visible rather than native client requirements."],
  ]),
  ...entries(N + "platform/lico_agent_driver/execution.rs", parameter("executable: &str"), [
    ["5d0555e57fe2", "Construct the ordinary Lico Agent process branch from the selected executable; Plan mode uses its separate required sandbox path, not a measurement-driven fallback."],
  ]),
  ...entries(N + "platform/lico_agent_driver/probe.rs", parameter("executable: &Path"), [
    ["e60bf875c7e5", "Construct the selected Lico Agent help probe to derive capability information; classification is not live readiness or an assertion about timeout behavior."],
    ["702f845b22dd", "Run the prepared Lico Agent help command through its output interface; this separate sink stays visible and does not authorize a live Agent probe."],
  ]),
  ...entries(DR + "local_service/process.rs", parameter("executable: &str"), [
    ["de96119a14bc", "Construct a local service process using the caller's executable and explicit command configurator before the service owner detaches it."],
  ]),
  ...entries(DR + "local_service/process.rs", {kind: "command", evidence: "command: &mut Command"}, [
    ["7e16ee355cb6", "Detach a source-declared caller-prepared std Command with platform process-group flags; the selected program cannot be inferred from the receiver name alone."],
  ]),
  ...entries(N + "platform/mcp_service_process.rs", parameter("binary: Option<&Path>"), [
    ["25b8c55d297b", "Run the MCP service generation the installed package store selects, supplying the owning CLI and selected home without linking the service into the kernel; a caller-supplied binary must canonicalize to that generation entry."],
  ]),
  ...entries(N + "platform/openclaw_driver/probe.rs", parameter("executable: &str"), [
    ["298e735358b7", "Construct OpenClaw's bounded capability probe from the selected local executable with the source-owned untrusted-Agent preparation."],
  ]),
  ...entries(N + "platform/openclaw_driver/supervision.rs", field("Command::new(&self.executable)"), [
    ["b394558a3eed", "Launch the local OpenClaw ACP branch using its configured executable when no runtime connection supplies the command; optional credentials remain in the existing environment boundary, not this review data."],
  ]),
  ...entries(N + "platform/openclaw_gateway/command.rs", parameter("executable: &str"), [
    ["67db765625fd", "Construct the selected OpenClaw local loopback gateway process with its owned state/config paths and explicit token removal; this record does not start or expose the service."],
  ]),
  ...entries(N + "platform/pi_driver/probe.rs", parameter("executable: &str"), [
    ["a1d56bc81241", "Construct the selected Pi capability probe with its existing supervisor deadline and scrubbed Agent environment, retaining the runtime executable interface."],
  ]),
  ...entries(N + "platform/pi_driver/supervision.rs", field("Command::new(&self.executable)"), [
    ["d78a9c014fe5", "Launch the configured Pi process with its source-owned launch arguments, caller workspace and supervised stdio."],
  ]),
  ...entries(N + "platform/process_sandbox/seatbelt.rs", parameter("runner: &Path"), [
    ["9c8d310fd7f2", "Construct the verified macOS sandbox boundary for a selected collaboration runner and owned manifest/snapshot paths; the guest executable is a caller input, not sandbox-exec itself."],
    ["9c8d310fd7f2#2", "Construct the required Lico Agent Plan sandbox around the selected runner, one plan file and bounded workspace; no runtime selection restriction or fallback is introduced for measurement."],
  ]),
  ...entries(N + "platform/process_sandbox/strategy.rs", parameter("executable: &Path"), [
    ["783b7b87c003", "Construct the strategy sandbox around the verified chosen script runtime, revision and scratch roots; Node/Python dependencies remain explicit runtime interfaces rather than zero debt."],
  ]),
  ...entries(SUPERVISOR, {kind: "command", evidence: "command: &mut Command"}, [
    ["0ed976fe744e", "Delegate an explicitly prepared untrusted Agent Command to the shared bounded capture owner after environment/workspace/stdin isolation; arbitrary caller program selection remains visible."],
  ]),
  ...entries(N + "platform/strategy_runtime/mod.rs", parameter("fn verify_runtime(kind: RuntimeKind, executable: &Path)"), [
    ["90131efac688", "Construct the version probe for a selected strategy runtime after path/permission checks, retaining canonicalized or configured runtime identity rather than inventing a literal executable."],
  ]),
  ...entries(N + "platform/strategy_runtime/mod.rs", command, [
    ["b39e0b100c0d", "Capture the selected strategy runtime version through the scrubbed bounded runner before creating its verified descriptor; this record does not make that dependency disappear."],
  ]),
  ...entries(SHELL, {kind: "environment", evidence: 'std::env::var_os("SHELL")'}, [
    ["3fd93d50e8fa", "Capture the user's login-shell environment using an existing SHELL path or platform fallback and fixed source-owned marker command; the shell path remains intentional runtime state."],
  ]),
  ...entries(SHELL, command, [
    ["cb586647e84a", "Capture the prepared login-shell command under the bounded process owner; environment values are runtime data and are not stored in this source review inventory."],
  ]),
  ...entries(MIGRATE_CONVERTER, field("entry: &'a Path"), [
    ["b9b764e7cf4a", "Run the converter program the selected package published for the required format pair; the entry inside the installed payload is the package's own declaration, and the store's digest and signed-index checks admitted those bytes before this process starts."],
  ]),
]);
