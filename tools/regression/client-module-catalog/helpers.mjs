import { classifyClientModule } from "../client-regression-metadata.mjs";

const REPO_ROOT = ".";
export const NATIVE_MANIFEST = "crates/licoup-native/Cargo.toml";
export const AGENT_DRIVERS_MANIFEST = "crates/licoup-agent-drivers/Cargo.toml";
export const ADAPTER_SDK_MANIFEST = "crates/licoup-agent-adapter-sdk/Cargo.toml";
// The generic local persistence owner lives in this crate, so its module
// regression commands run against it rather than against the command layer.
export const CLIENT_STATE_MANIFEST = "crates/licoup-client-state/Cargo.toml";
export const FOUNDATION_MANIFEST = "crates/licoup-foundation/Cargo.toml";
// The endpoint-owned LicoArc envelope codec lives in this crate, so its module
// regression commands run against it rather than against the native host.
export const PROTOCOL_BINDINGS_MANIFEST = "crates/licoup-protocol-bindings/Cargo.toml";
// Composition and session policy live in this crate, so the modules that moved
// there run their tests against its manifest rather than against the host.
export const APPLICATION_MANIFEST = "crates/licoup-application/Cargo.toml";
// The mesh cryptography lives in this crate, so the modules that moved there run
// their tests against its manifest rather than against the host.
export const SECURE_MESH_MANIFEST = "crates/licoup-secure-mesh/Cargo.toml";
// The relay trust and transport base lives in this crate, so the modules that moved
// there run their tests against its manifest rather than against the host.
export const RELAY_MANIFEST = "crates/licoup-relay/Cargo.toml";
// The MCP registry, transport and approval authority lives in this crate, so its
// module regression commands run against that manifest rather than the host.
export const MCP_MANIFEST = "crates/licoup-mcp/Cargo.toml";
// The Agent inventory — the target declarations, their discovery and the
// packaged scan-path manifest — lives in this crate, so the modules that moved
// there run their tests against its manifest rather than against the host.
export const AGENT_TARGETS_MANIFEST = "crates/licoup-agent-targets/Cargo.toml";

export const FLUTTER_COMPOSITION_INPUTS = Object.freeze([
  "apps/desktop/analysis_options.yaml",
  "apps/desktop/test/flutter_test_config.dart",
  "apps/desktop/pubspec.lock",
  "apps/desktop/pubspec.yaml",
]);

export const RUST_COMPOSITION_INPUTS = Object.freeze([
  "Cargo.lock",
  "Cargo.toml",
  NATIVE_MANIFEST,
  FOUNDATION_MANIFEST,
  PROTOCOL_BINDINGS_MANIFEST,
  APPLICATION_MANIFEST,
  SECURE_MESH_MANIFEST,
  RELAY_MANIFEST,
  MCP_MANIFEST,
  AGENT_TARGETS_MANIFEST,
  "crates/licoup-native/src/core/mod.rs",
  "crates/licoup-native/src/domain/mod.rs",
  "crates/licoup-application/src/integration_state.rs",
  "crates/licoup-native/src/ffi/commands/mod.rs",
  "crates/licoup-native/src/ffi/mod.rs",
  "crates/licoup-native/src/lib.rs",
  "crates/licoup-native/src/domain/target_port.rs",
  "crates/licoup-native/src/platform/mod.rs",
]);

export const ANDROID_SECURE_MESH_LEAF_INPUTS = Object.freeze([
  "apps/desktop/android/app/src/main/kotlin/land/lico/licoup/MainActivity.kt",
  "apps/desktop/android/app/src/main/kotlin/land/lico/licoup/SecureMeshAndroidBridgeContract.kt",
  "apps/desktop/android/app/src/main/kotlin/land/lico/licoup/SecureMeshAndroidNativeRuntime.kt",
  "apps/desktop/android/app/src/main/kotlin/land/lico/licoup/SecureMeshAndroidCommandRouter.kt",
  "apps/desktop/android/app/src/main/kotlin/land/lico/licoup/SecureMeshAndroidJsonCodec.kt",
  "apps/desktop/android/app/src/main/kotlin/land/lico/licoup/SecureMeshAndroidRuntimeStatusStore.kt",
  "apps/desktop/android/app/src/main/kotlin/land/lico/licoup/SecureMeshAndroidSecretStore.kt",
  "apps/desktop/android/app/src/main/kotlin/land/lico/licoup/SecureMeshAndroidSecretContract.kt",
  "apps/desktop/android/app/src/main/kotlin/land/lico/licoup/SecureMeshAndroidCustodyManager.kt",
  "apps/desktop/android/app/src/main/kotlin/land/lico/licoup/SecureMeshAndroidEncryptedRecordStore.kt",
  "apps/desktop/android/app/src/main/kotlin/land/lico/licoup/SecureMeshAndroidMobileRelaySecretBridge.kt",
  "apps/desktop/android/app/src/debug/kotlin/land/lico/licoup/DebugMainActivity.kt",
  "apps/desktop/android/app/src/debug/kotlin/land/lico/licoup/ReleaseAcceptanceChannel.kt",
  "apps/desktop/android/app/src/debug/kotlin/land/lico/licoup/ReleaseAcceptanceDebugCodec.kt",
  "apps/desktop/android/app/src/debug/kotlin/land/lico/licoup/ReleaseAcceptanceDebugContract.kt",
  "apps/desktop/android/app/src/debug/kotlin/land/lico/licoup/ReleaseAcceptanceIngress.kt",
  "apps/desktop/android/app/src/debug/kotlin/land/lico/licoup/SecureMeshAndroidReleaseAcceptanceCoordinator.kt",
  "apps/desktop/android/app/src/main/AndroidManifest.xml",
  "apps/desktop/android/app/src/debug/AndroidManifest.xml",
  "apps/desktop/android/app/src/main/res/xml/backup_rules.xml",
  "apps/desktop/android/app/src/main/res/xml/backup_rules_legacy.xml",
]);

export const FAKE_AGENT_SERVICE_INPUTS = Object.freeze([
  "apps/desktop/test/fixtures/client_controller/support/fake_agent_service.dart",
  "apps/desktop/test/fixtures/client_controller/support/fake_agent_state_support.dart",
  "apps/desktop/test/fixtures/client_controller/support/fake_agent_conversation_support.dart",
  "apps/desktop/test/fixtures/client_controller/support/fake_agent_conversation_fixture.dart",
  "apps/desktop/test/fixtures/client_controller/support/fake_agent_archive_support.dart",
  "apps/desktop/test/fixtures/client_controller/support/fake_agent_archive_job_fixture.dart",
  "apps/desktop/test/fixtures/client_controller/support/fake_agent_usage_support.dart",
  "apps/desktop/test/fixtures/client_controller/support/fake_agent_runtime_support.dart",
]);

export function command(program, args, timeoutMs) {
  return Object.freeze({
    program,
    args: Object.freeze([...args]),
    cwd: REPO_ROOT,
    timeoutMs,
  });
}

export function node(script, args = [], timeoutMs = 120_000) {
  return command("node", [script, ...args], timeoutMs);
}

export function flutterTests(testPaths) {
  return node(
    "tools/scripts/client-toolchain-runner.mjs",
    [
      "--check",
      "flutter",
      "--cwd",
      "apps/desktop",
      "--",
      "flutter",
      "test",
      "--no-pub",
      ...testPaths,
    ],
    5 * 60_000,
  );
}

export function flutterTestsMatching(testPaths, namePattern) {
  return node(
    "tools/scripts/client-toolchain-runner.mjs",
    [
      "--check",
      "flutter",
      "--cwd",
      "apps/desktop",
      "--",
      "flutter",
      "test",
      "--no-pub",
      ...testPaths,
      "--name",
      namePattern,
    ],
    5 * 60_000,
  );
}

export function flutterAnalyze() {
  return node(
    "tools/scripts/client-toolchain-runner.mjs",
    [
      "--check",
      "flutter",
      "--cwd",
      "apps/desktop",
      "--",
      "flutter",
      "analyze",
      "--no-pub",
    ],
    5 * 60_000,
  );
}

export function androidGradle(args, timeoutMs = 5 * 60_000) {
  return node(
    "tools/scripts/client-toolchain-runner.mjs",
    [
      "--cwd",
      "apps/desktop/android",
      "--",
      "./gradlew",
      ...args,
      ...(args.includes("--offline") ? [] : ["--offline"]),
    ],
    timeoutMs,
  );
}

export function rustLayer(filter, harnessArgs = []) {
  return command(
    "cargo",
    [
      "test",
      "--manifest-path",
      NATIVE_MANIFEST,
      "--lib",
      filter,
      ...(harnessArgs.length > 0 ? ["--", ...harnessArgs] : []),
    ],
    10 * 60_000,
  );
}

// The ACP session transport and the local service control plane now live in
// `licoup-agent-drivers`, so a module whose inputs moved there must run against
// that crate's manifest: a filter left on the native manifest matches zero
// tests and reports the module green without executing one.
export function rustAgentDriversLayer(filter, harnessArgs = []) {
  return command(
    "cargo",
    [
      "test",
      "--manifest-path",
      AGENT_DRIVERS_MANIFEST,
      "--lib",
      filter,
      ...(harnessArgs.length > 0 ? ["--", ...harnessArgs] : []),
    ],
    10 * 60_000,
  );
}

export function rustAdapterSdkLayer(filter, harnessArgs = []) {
  return command(
    "cargo",
    [
      "test",
      "--manifest-path",
      ADAPTER_SDK_MANIFEST,
      "--lib",
      filter,
      ...(harnessArgs.length > 0 ? ["--", ...harnessArgs] : []),
    ],
    10 * 60_000,
  );
}

export function rustClientStateLayer(filter, harnessArgs = []) {
  return command(
    "cargo",
    [
      "test",
      "--manifest-path",
      CLIENT_STATE_MANIFEST,
      "--lib",
      filter,
      ...(harnessArgs.length > 0 ? ["--", ...harnessArgs] : []),
    ],
    10 * 60_000,
  );
}

// A module whose code lives in `licoup-foundation` must run its tests against that
// crate's manifest. A dependency's `#[cfg(test)]` items are not compiled into the
// dependent's test binary, so filtering them against `crates/licoup-native` matches
// zero tests and the module reports green without executing one.
export function rustFoundationLayer(filter, harnessArgs = []) {
  return command(
    "cargo",
    [
      "test",
      "--manifest-path",
      FOUNDATION_MANIFEST,
      "--lib",
      filter,
      ...(harnessArgs.length > 0 ? ["--", ...harnessArgs] : []),
    ],
    10 * 60_000,
  );
}

// The same rule for the endpoint-owned LicoArc envelope codec, which now lives in
// `licoup-protocol-bindings` and is compiled into `licoup-native` without its
// `#[cfg(test)]` items.
export function rustProtocolBindingsLayer(filter, harnessArgs = []) {
  return command(
    "cargo",
    [
      "test",
      "--manifest-path",
      PROTOCOL_BINDINGS_MANIFEST,
      "--lib",
      filter,
      ...(harnessArgs.length > 0 ? ["--", ...harnessArgs] : []),
    ],
    10 * 60_000,
  );
}

// The same rule for client composition and session policy, which now live in
// `licoup-application` and are compiled into `licoup-native` without their
// `#[cfg(test)]` items.
export function rustApplicationLayer(filter, harnessArgs = []) {
  return command(
    "cargo",
    [
      "test",
      "--manifest-path",
      APPLICATION_MANIFEST,
      "--lib",
      filter,
      ...(harnessArgs.length > 0 ? ["--", ...harnessArgs] : []),
    ],
    10 * 60_000,
  );
}

// The same rule for the mesh cryptography, which now lives in
// `licoup-secure-mesh` and is compiled into `licoup-native` without its
// `#[cfg(test)]` items.
// The same rule for the MCP registry, transport and approval, which now live in
// `licoup-mcp` and are compiled into `licoup-native` without their `#[cfg(test)]`
// items.
export function rustMcpLayer(filter, harnessArgs = []) {
  return command(
    "cargo",
    [
      "test",
      "--manifest-path",
      MCP_MANIFEST,
      "--lib",
      filter,
      ...(harnessArgs.length > 0 ? ["--", ...harnessArgs] : []),
    ],
    10 * 60_000,
  );
}

// The same rule for the relay trust and transport base, which now lives in
// `licoup-relay` and is compiled into `licoup-native` without its `#[cfg(test)]`
// items.
export function rustRelayLayer(filter, harnessArgs = []) {
  return command(
    "cargo",
    [
      "test",
      "--manifest-path",
      RELAY_MANIFEST,
      "--lib",
      filter,
      ...(harnessArgs.length > 0 ? ["--", ...harnessArgs] : []),
    ],
    10 * 60_000,
  );
}

// The same rule for the Agent inventory, which now lives in
// `licoup-agent-targets` and is compiled into `licoup-native` without its
// `#[cfg(test)]` items.
export function rustAgentTargetsLayer(filter, harnessArgs = []) {
  return command(
    "cargo",
    [
      "test",
      "--manifest-path",
      AGENT_TARGETS_MANIFEST,
      "--lib",
      filter,
      ...(harnessArgs.length > 0 ? ["--", ...harnessArgs] : []),
    ],
    10 * 60_000,
  );
}

export function rustSecureMeshLayer(filter, harnessArgs = []) {
  return command(
    "cargo",
    [
      "test",
      "--manifest-path",
      SECURE_MESH_MANIFEST,
      "--lib",
      filter,
      ...(harnessArgs.length > 0 ? ["--", ...harnessArgs] : []),
    ],
    10 * 60_000,
  );
}

export function rustCrateIntegrationTest(crate, target, features = []) {
  return command(
    "cargo",
    [
      "test",
      "-p",
      crate,
      ...(features.length > 0 ? ["--features", features.join(",")] : []),
      "--test",
      target,
    ],
    10 * 60_000,
  );
}

export function rustIntegrationTest(target, filter) {
  return command(
    "cargo",
    [
      "test",
      "--manifest-path",
      NATIVE_MANIFEST,
      "--test",
      target,
      ...(filter ? [filter] : []),
    ],
    10 * 60_000,
  );
}

// A binary whose code moved to `licoup-secure-mesh` runs its tests against that
// crate's manifest. A filter left on the manifest that no longer holds the
// binary matches zero tests and reports green.
export function rustSecureMeshBinaryTests(binary, filter, features = []) {
  return command(
    "cargo",
    [
      "test",
      "-p",
      "licoup-secure-mesh",
      ...(features.length > 0 ? ["--features", features.join(",")] : []),
      "--bin",
      binary,
      filter,
    ],
    10 * 60_000,
  );
}

export function rustBinaryTests(binary, filter, features = []) {
  return command(
    "cargo",
    [
      "test",
      "-p",
      "licoup-native",
      ...(features.length > 0 ? ["--features", features.join(",")] : []),
      "--bin",
      binary,
      filter,
    ],
    10 * 60_000,
  );
}

export function defineModule({ id, kind, summary, inputs, command: moduleCommand }) {
  const regression = classifyClientModule({ id, kind, command: moduleCommand });
  return Object.freeze({
    id,
    kind,
    summary,
    inputs: Object.freeze([...new Set(inputs)]),
    command: moduleCommand,
    regression,
  });
}

// A secure-mesh module whose code has moved to `licoup-secure-mesh` must name that
// crate's path and run against its manifest, or the filter matches zero tests
// there and the module reports green without executing one.
export function secureMeshModule({
  id,
  summary,
  source,
  resources = [],
  testInputs = [],
  origin = "crates/licoup-native",
}) {
  const relocated = origin === "crates/licoup-secure-mesh";
  return defineModule({
    id,
    kind: "rust-core",
    summary,
    inputs: [`${origin}/src/core/${source}.rs`, ...testInputs, ...resources],
    command: (relocated ? rustSecureMeshLayer : rustLayer)(`core::${source}::tests`),
  });
}

export function assembleClientModuleCatalog(idOrder, moduleGroups) {
  if (!Array.isArray(idOrder) || !Array.isArray(moduleGroups)) {
    throw new Error("client module catalog assembly inputs are invalid");
  }
  const expectedIds = new Set();
  for (const id of idOrder) {
    if (expectedIds.has(id)) {
      throw new Error(`duplicate client module order id: ${id}`);
    }
    expectedIds.add(id);
  }

  const moduleById = new Map();
  for (const group of moduleGroups) {
    if (!Array.isArray(group)) {
      throw new Error("client module catalog group must be an array");
    }
    for (const module of group) {
      if (moduleById.has(module.id)) {
        throw new Error(`duplicate client module definition: ${module.id}`);
      }
      moduleById.set(module.id, module);
    }
  }

  const missing = idOrder.filter((id) => !moduleById.has(id));
  if (missing.length > 0) {
    throw new Error(`missing client module definitions: ${missing.join(", ")}`);
  }
  const unexpected = [...moduleById.keys()].filter((id) => !expectedIds.has(id));
  if (unexpected.length > 0) {
    throw new Error(`unexpected client module definitions: ${unexpected.join(", ")}`);
  }
  return Object.freeze(idOrder.map((id) => moduleById.get(id)));
}
