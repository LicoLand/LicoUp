/**
 * Reviewed runtime-selected process interfaces, not permissions or exclusions.
 * Exact source digests intentionally require review after source changes.
 * New sites never inherit a neighbouring record or a file-level tool mention.
 */
const N = "crates/licoup-native/src/";
// The Codex adapter package owns the one Agent whose process an extension host
// starts; its reviewed launch sites are keyed here rather than under N.
const C = "crates/licoup-agent-codex/src/";
// The DeepSeek Harness adapter package owns the process its reviewed launch
// runs; VENDOR-CODE-REMOVAL moved that site out of the host, so its record is
// keyed here rather than under N. Its leaf is the package's `driver` root.
const DS = "crates/licoup-agent-deepseek/src/";
// The seven adapter packages below own the driver leaves VENDOR-CODE-REMOVAL
// moved out of the host's `platform/<target>_driver` trees. Every reviewed site
// whose file moved is keyed at its package root, because the path is part of
// both the source digest and the site's own identity: a move deletes one
// tracked member and creates another.
const AG = "crates/licoup-agent-antigravity/src/";
const CC = "crates/licoup-agent-claude-code/src/";
const CU = "crates/licoup-agent-cursor/src/";
const HE = "crates/licoup-agent-hermes/src/";
const LA = "crates/licoup-agent-lico-agent/src/";
const OC = "crates/licoup-agent-openclaw/src/";
const PI = "crates/licoup-agent-pi/src/";
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
  "crates/licoup-mcp/src/application.rs": "bbc38e974fdc0a087a4d5e89350530bbe531e680bea8aac56562d109604832cc",
  [N + "domain/agent_hub/argv.rs"]: "4f942a0f7df3f2e2e8396a40906381811ae6dcd656c2a7bcf9d7ceb5c214d911",
  [N + "domain/agent_hub/version_check.rs"]: "31b09b2189abae030fa32436cb3b02a0be885105a2cbd41ea40b5c7fb7c0ee65",
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
  [T + "domain/targets/model_catalog/kilo.rs"]: "1945c633ad10cb99c2dc62e063e2778c8d7930eee17d7eeedb9c75eabc531dfe",
  [T + "domain/targets/model_catalog/opencode.rs"]: "e20e6e35d4e13d55f3359c3356b9f480a13a8a7f80249dd035fdf2b62e96ac20",
  [T + "domain/targets/model_catalog/pi.rs"]: "22466bce8b6d17b8125cbcb036ccd549e64867b56fdbf3883589610f0dcc3f2e",
  [PARAMETERS]: "43cdd22e2653747415a63b54cf508b35b8250d77b12c914c69925cc8f398bf8b",
  [T + "domain/targets/virtual_machine_discovery.rs"]: "c2132da0c5a99e8f913a16c79e0e836510e831fc2a83970e8904da7dc0fca89e",
  [DR + "acp_driver_runtime/supervision.rs"]: "7300984d196c6a73ba67e82b6a96c8c90e41b8540f7b03e7e6a7a7968c31705b",
  [DR + "acp_session_transport/command.rs"]: "b16fc8b4383c2b27693417d311200d15fefd047c8929be51d9bf98dc6305da9d",
  [DR + "local_service/process.rs"]: "40c1858f9ddf63679d771bb3f38ec4401ce7e75aa957ff29488ab3154117b9d9",
  [AG + "driver/auth.rs"]: "2edad01ad0e4fcd9053a898ae289d7a9d509445522ff667e9a6aa9306b8b3a0c",
  [AG + "driver/execution.rs"]: "62b01f3fdf637be6dad6f64d0d3b99fbf4a7cbfb696bc15f1ef0386d6d2b2d38",
  [AG + "driver/probe.rs"]: "8dd261105d35c2df1c884ccc60b52a475b309a36753df72777cb16185122cb8a",
  [CC + "driver/launch.rs"]: "8153fb7e04bf948c8d7101443eb34d21e1a7248ce2a61007c7bd0d4c4e5fd7cb",
  [CC + "driver/probe.rs"]: "73331f65b4f41f2553adb16105f3978fb9fc5f66e8ff4395d3fc924ff86b068f",
  [C + "app_server/driver/launch.rs"]: "de5dfbad8261b94a1bb37d1bf9ae4620af35e1856434b16c74b5ad7cc9f8b862",
  [CU + "driver/execution.rs"]: "2f48be9f5539175f728dbd5bbda0bac747b25b6c39d139c223662fcd6237a759",
  [CU + "driver/probe.rs"]: "f551efaa5692c8a85281e6fc3f5cb462e42485d48e0dfd4a5e1dc4974cedcbda",
  [DS + "driver.rs"]: "6ff0622a273dcc0c0f4ab829e5dd5803aac38df24937667c71412c980f2d5503",
  [N + "platform/extension_host/isolation/confinement.rs"]: "2cc72396a086eea81f47ce7fabe818dd4b5f2c054d3280e06c45cd8ac8046956",
  [N + "platform/generic_cli_driver.rs"]: "6970fd309539bbfa2d5b4fbd7191cb292b86b5b1a3f1ebdde8b184c7747c6341",
  [HE + "driver/probe.rs"]: "a08f7c633acf3aeb9c40fc8f9340850fa0f25d4fc08262727d339c3ca5c3b5f8",
  [LA + "driver/execution.rs"]: "8ff3049d7a88725d8c1e54cdc4176a2a3d1fe0a433161f1aaa99d5568333faf2",
  [LA + "driver/probe.rs"]: "c7dde852a23e43b3bd49671f0239d68ae6213e904338a51e5003361c62409baa",
  [MIGRATE_CONVERTER]: "1a468623ec8a3a0d23371c0dad7fdfdcb145f5cd6886cb306776c6f3acc59277",
  [N + "platform/mcp_service_process.rs"]: "745cd52c988672ebdfee6a52d020c02f0d56f62a6c9acd3247ee38109d5a6976",
  [OC + "driver/probe.rs"]: "99b23abd8c5205d362bf941ad730223a5d45ab7a74bbdf980a845b35078c4350",
  [OC + "driver/supervision.rs"]: "600999fb05c0f81f0ad99c0e7644a2e604dd91b779e88dc2c3d8147c97654376",
  [N + "platform/openclaw_gateway/command.rs"]: "5b747fa62fa6cd21074aa05990cf195377eeafed75907262598c40a1ac842601",
  [PI + "driver/probe.rs"]: "a65e50c269a358721ba391602937e4b7528da11f67f6c74f9587b40e98ce1b46",
  [PI + "driver/supervision.rs"]: "4998ffa3c372839e50867423369816c34893956eebd9794c2989600d1628c762",
  [N + "platform/process_sandbox/seatbelt.rs"]: "9d021bd1cc6158422c003f003742e15e6b861f3481100f21b8493bab2bb6fd4b",
  [N + "platform/process_sandbox/strategy.rs"]: "a8832eb3055c1dd7fde3e99c413aa92ec8c6e98a51a89345d4b377b8440d66f4",
  [SUPERVISOR]: "cc54d42dbc06636b95f686587c05bea047396d0652d1561a1abe6c99d7fff700",
  [N + "platform/strategy_runtime/mod.rs"]: "2aec0783434e79e87923b91eef2710e19a77d85dea84a1e1807898bf5d58cfd0",
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
    ["c87e251bea3b", "The independent MCP process starts its owning CLI from the host-provided LICOUP_CLI_BINARY binding for rpc stdio; this is a native bridge, not permission to run an arbitrary remote command."],
  ], [N + "platform/mcp_service_process.rs"]),
  ...entries(N + "domain/agent_hub/argv.rs", parameter("program: &str"), [
    ["db471ee64ae2", "Agent Hub lifecycle execution accepts a validated program/argv pair from the selected vendor installation channel; package-manager use is visible here, not hidden as a native client prerequisite."],
  ]),
  ...entries(N + "domain/agent_hub/version_check.rs", parameter("program: &Path"), [
    ["599a57a1fc1d", "Probe the installed Agent's supplied executable binding with a bounded version command; available installation paths and wrapper identities are runtime data."],
  ]),
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
  ...entries(AG + "driver/auth.rs", parameter("executable: Option<&str>"), [
    ["1f43c2254fdf", "Construct the Antigravity OAuth-start command using an optional selected executable and vendor default; this source review does not grant or verify consent for that external authorization effect."],
  ]),
  ...entries(AG + "driver/auth.rs", parameter("fn probe_authorization(executable: &str)"), [
    ["1f43c2254fdf#2", "Construct the selected Antigravity models-based authorization probe before a turn, keeping the separate consent boundary for actually starting OAuth."],
  ]),
  ...entries(AG + "driver/execution.rs", parameter("executable: &str"), [
    ["4d6b7c2ac975", "Launch an Antigravity turn through the caller-selected executable with admitted configuration and scoped Membership/MCP context; runtime selection remains unconstrained by the metric."],
  ]),
  ...entries(AG + "driver/probe.rs", parameter("executable: &str"), [
    ["af3c6f7a09e0", "Construct the bounded Antigravity version/help capability probe around the executable supplied by its driver, with untrusted-Agent environment preparation."],
  ]),
  ...entries(CC + "driver/launch.rs", field("Command::new(&identity.executable)"), [
    ["aad8f9c47807", "Launch the configured Claude Code process with source-owned arguments and workspace, retaining the executable-directory PATH head needed by sibling vendor tools."],
  ]),
  ...entries(CC + "driver/probe.rs", parameter("executable: &str"), [
    ["a8508623e986", "Construct Claude Code's bounded capability probe from its caller-selected executable; the source supervisor and untrusted environment remain separate runtime guarantees."],
  ]),
  ...entries(C + "app_server/driver/launch.rs", field("Command::new(&self.executable)"), [
    ["0727a31cdeef", "Launch the installed Codex client's app-server for one turn with stdio and the scoped launch environment: the portable LicoUp root and the Membership caller context are bound explicitly, and neither is inferred from a fixed executable spelling. The site is the Codex adapter package's, so it is the same launch whether the client composes the package or an extension host starts the package's own program; the executable is always a caller-selected path and never a literal tool name."],
  ]),
  ...entries(CU + "driver/execution.rs", parameter("executable: &str"), [
    ["4af69fdcbd65", "Create a Cursor chat session using the selected Agent executable and bounded workspace, with the same scoped caller context as the resumed turn."],
    ["4af69fdcbd65#2", "Execute the resumed Cursor turn using the selected executable, explicit workspace/session arguments and supervised transport; it is not the chat-creation invocation."],
  ]),
  ...entries(CU + "driver/probe.rs", parameter("executable: &str"), [
    ["240c5b139c44", "Construct the bounded Cursor capability probe from the driver-supplied executable, preserving its environment isolation and output handling."],
  ]),
  ...entries(DS + "driver.rs", field("Command::new(&config.executable)"), [
    ["b0f6bd00169d", "Start the configured DeepSeek Harness SDK-profile JSON-RPC carrier under its workspace and supervised stdio; this is an Agent runtime binding, not a fixed native artifact."],
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
  ...entries(HE + "driver/probe.rs", parameter("executable: &str"), [
    ["1763805bb64e", "Construct the bounded Hermes capability probe from its runtime executable binding; external Agent interpreter requirements remain visible rather than native client requirements."],
  ]),
  ...entries(LA + "driver/execution.rs", parameter("executable: &str"), [
    ["331cdcc47e87", "Construct the ordinary Lico Agent process branch from the selected executable; Plan mode uses its separate required sandbox path, not a measurement-driven fallback."],
  ]),
  ...entries(LA + "driver/probe.rs", parameter("executable: &Path"), [
    ["dfaf4adc46fe", "Construct the selected Lico Agent help probe to derive capability information; classification is not live readiness or an assertion about timeout behavior."],
    ["1ad3bfd9d1b8", "Run the prepared Lico Agent help command through its output interface; this separate sink stays visible and does not authorize a live Agent probe."],
  ]),
  ...entries(DR + "local_service/process.rs", parameter("executable: &str"), [
    ["de96119a14bc", "Construct a local service process using the caller's executable and explicit command configurator before the service owner detaches it."],
  ]),
  ...entries(DR + "local_service/process.rs", {kind: "command", evidence: "command: &mut Command"}, [
    ["7e16ee355cb6", "Detach a source-declared caller-prepared std Command with platform process-group flags; the selected program cannot be inferred from the receiver name alone."],
  ]),
  ...entries(N + "platform/mcp_service_process.rs", parameter("binary: Option<&Path>"), [
    ["25b8c55d297b", "Run the MCP service generation the installed package store selects, supplying the owning CLI and selected home without linking the service into the kernel: start, stop, reload and reconcile all go through that generation's own program, which owns the service's writer lease, while this module keeps the lease naming the generation, its measured payload digest and its callers. The install record's content digest is the approval, and the payload digest measured at selection is handed to that program, so bytes that no longer measure the same are refused rather than started; a caller-supplied binary must canonicalize to that generation entry."],
  ]),
  ...entries(OC + "driver/probe.rs", parameter("executable: &str"), [
    ["19464e17c91d", "Construct OpenClaw's bounded capability probe from the selected local executable with the source-owned untrusted-Agent preparation."],
  ]),
  ...entries(OC + "driver/supervision.rs", field("Command::new(&self.executable)"), [
    ["32f10a589886", "Launch the local OpenClaw ACP branch using its configured executable when no runtime connection supplies the command; optional credentials remain in the existing environment boundary, not this review data."],
  ]),
  ...entries(N + "platform/openclaw_gateway/command.rs", parameter("executable: &str"), [
    ["67db765625fd", "Construct the selected OpenClaw local loopback gateway process with its owned state/config paths and explicit token removal; this record does not start or expose the service."],
  ]),
  ...entries(PI + "driver/probe.rs", parameter("executable: &str"), [
    ["1e811859d365", "Construct the selected Pi capability probe with its existing supervisor deadline and scrubbed Agent environment, retaining the runtime executable interface."],
  ]),
  ...entries(PI + "driver/supervision.rs", field("Command::new(&self.executable)"), [
    ["e029234d24d5", "Launch the configured Pi process with its source-owned launch arguments, caller workspace and supervised stdio."],
  ]),
  ...entries(N + "platform/process_sandbox/seatbelt.rs", parameter("runner: &Path"), [
    ["cc760a308639", "Construct the verified macOS sandbox boundary for a selected collaboration runner and owned manifest/snapshot paths; the guest executable is a caller input, not sandbox-exec itself."],
    ["cc760a308639#2", "Construct the required Lico Agent Plan sandbox around the selected runner, one plan file and bounded workspace; no runtime selection restriction or fallback is introduced for measurement."],
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
