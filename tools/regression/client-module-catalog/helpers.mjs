const REPO_ROOT = ".";
export const NATIVE_MANIFEST = "crates/licoup-native/Cargo.toml";

export const FLUTTER_COMPOSITION_INPUTS = Object.freeze([
  "apps/desktop/analysis_options.yaml",
  "apps/desktop/pubspec.lock",
  "apps/desktop/pubspec.yaml",
]);

export const RUST_COMPOSITION_INPUTS = Object.freeze([
  "Cargo.lock",
  "Cargo.toml",
  NATIVE_MANIFEST,
  "crates/licoup-native/src/core/mod.rs",
  "crates/licoup-native/src/domain/mod.rs",
  "crates/licoup-native/src/ffi/commands/mod.rs",
  "crates/licoup-native/src/ffi/mod.rs",
  "crates/licoup-native/src/lib.rs",
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
      filter,
      ...(harnessArgs.length > 0 ? ["--", ...harnessArgs] : []),
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
  return Object.freeze({
    id,
    kind,
    summary,
    inputs: Object.freeze([...new Set(inputs)]),
    command: moduleCommand,
  });
}

export function secureMeshModule({
  id,
  summary,
  source,
  resources = [],
  testInputs = [],
}) {
  return defineModule({
    id,
    kind: "rust-core",
    summary,
    inputs: [
      `crates/licoup-native/src/core/${source}.rs`,
      ...testInputs,
      ...resources,
    ],
    command: rustLayer(`core::${source}::tests`),
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
