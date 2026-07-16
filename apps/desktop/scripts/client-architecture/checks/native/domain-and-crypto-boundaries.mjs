import path from "node:path";

export async function checkDomainAndCryptoBoundaries(context) {
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
  const clientUpdateRoot = "crates/lico-client-native/src/domain/client_update";
  const clientUpdateFacadeSource = await readText(`${clientUpdateRoot}.rs`);
  const clientUpdateDeclaredModules = [...clientUpdateFacadeSource
    .matchAll(/^mod ([a-z_]+);$/gm)]
    .map((match) => match[1])
    .filter((moduleName) => moduleName !== "tests");
  assert(
    sameSet(clientUpdateDeclaredModules, [
      "apply",
      "canonical",
      "check",
      "constants",
      "dispatch",
      "download",
      "keys",
      "macos_runner",
      "metadata",
      "model",
      "params",
      "release",
      "revocation",
      "selection",
      "signature",
      "staging",
      "status",
      "verify",
    ]),
    "client update facade must declare its complete ordinary-module authority exactly once"
  );
  assert(
    !clientUpdateFacadeSource.includes("#[path") &&
      !clientUpdateFacadeSource.includes("include!(") &&
      !clientUpdateFacadeSource.includes("mod tests {") &&
      !clientUpdateFacadeSource.includes("impl "),
    "client update root must remain a thin ordinary-module facade"
  );
  const clientUpdateFoundationSource = await readJoinedText([
    `${clientUpdateRoot}/canonical.rs`,
    `${clientUpdateRoot}/constants.rs`,
    `${clientUpdateRoot}/model.rs`,
    `${clientUpdateRoot}/params.rs`,
  ]);
  for (const operationDependency of [
    "apply::",
    "check::",
    "dispatch::",
    "download::",
    "macos_runner::",
    "selection::",
    "staging::",
    "status::",
    "verify::",
  ]) {
    assert(
      !clientUpdateFoundationSource.includes(operationDependency),
      `client update foundation must not depend on operation module ${operationDependency}`
    );
  }
  const clientUpdateOutputSource = await readJoinedText([
    `${clientUpdateRoot}/apply.rs`,
    `${clientUpdateRoot}/check.rs`,
    `${clientUpdateRoot}/download.rs`,
    `${clientUpdateRoot}/macos_runner/lifecycle.rs`,
    `${clientUpdateRoot}/status.rs`,
    `${clientUpdateRoot}/verify.rs`,
  ]);
  for (const privatePathField of [
    "installedAppPath",
    "restoredFrom",
    "sourcePath",
    "stagedAppPath",
  ]) {
    assert(
      !clientUpdateOutputSource.includes(`"${privatePathField}":`),
      `client update output must not expose private path field ${privatePathField}`
    );
  }
  const clientUpdateTestFiles = (await collectSourceFiles(
    `${clientUpdateRoot}/tests`,
    ".rs"
  )).map((relativePath) => path.basename(relativePath));
  assert(
    sameSet(clientUpdateTestFiles, [
      "artifact_binding.rs",
      "macos_runner.rs",
      "release_selection.rs",
      "revocation.rs",
      "signature_roles.rs",
      "staging_paths.rs",
      "support.rs",
      "workflow.rs",
    ]),
    "client update regression support must remain split into independently selectable leaves"
  );

  const agentUsageCodexRoot =
    "crates/lico-client-native/src/domain/agent_usage/agent_usage_codex";
  const agentUsageCodexProductionLimits = new Map([
    [`${agentUsageCodexRoot}/aggregation.rs`, 250],
    [`${agentUsageCodexRoot}/append_guard.rs`, 80],
    [`${agentUsageCodexRoot}/cache.rs`, 190],
    [`${agentUsageCodexRoot}/cache_batch.rs`, 220],
    [`${agentUsageCodexRoot}/constants.rs`, 15],
    [`${agentUsageCodexRoot}/event_hash.rs`, 100],
    [`${agentUsageCodexRoot}/file_collection.rs`, 90],
    [`${agentUsageCodexRoot}/lineage.rs`, 100],
    [`${agentUsageCodexRoot}/models.rs`, 150],
    [`${agentUsageCodexRoot}/parser.rs`, 300],
    [`${agentUsageCodexRoot}/scan.rs`, 190],
    [`${agentUsageCodexRoot}/scan_params.rs`, 100],
    [`${agentUsageCodexRoot}/utils.rs`, 70]
  ]);
  const agentUsageCodexTestLeaves = [
    "aggregation.rs",
    "append_guard.rs",
    "cache.rs",
    "cache_batch.rs",
    "event_hash.rs",
    "file_collection.rs",
    "lineage.rs",
    "mod.rs",
    "models.rs",
    "parser.rs",
    "scan_params.rs",
    "support.rs",
    "utils.rs"
  ].map((leaf) => `${agentUsageCodexRoot}/tests/${leaf}`);
  const agentUsageCodexFiles = await collectSourceFiles(agentUsageCodexRoot, ".rs");
  const discoveredAgentUsageCodexProduction = agentUsageCodexFiles
    .filter((relativePath) => !relativePath.startsWith(`${agentUsageCodexRoot}/tests/`));
  const discoveredAgentUsageCodexTests = agentUsageCodexFiles
    .filter((relativePath) => relativePath.startsWith(`${agentUsageCodexRoot}/tests/`));
  assert(
    sameSet(
      discoveredAgentUsageCodexProduction,
      [...agentUsageCodexProductionLimits.keys()]
    ),
    "Codex usage facade must own the complete explicit production leaf set"
  );
  assert(
    sameSet(discoveredAgentUsageCodexTests, agentUsageCodexTestLeaves),
    "Codex usage regression support must remain physically split into explicit leaves"
  );
  const agentUsageCodexFacadeSource = await readText(`${agentUsageCodexRoot}.rs`);
  const declaredAgentUsageCodexModules = [...agentUsageCodexFacadeSource
    .matchAll(/^mod ([a-z_]+);$/gm)]
    .map((match) => match[1])
    .filter((moduleName) => moduleName !== "tests")
    .map((moduleName) => `${agentUsageCodexRoot}/${moduleName}.rs`);
  assert(
    sameSet(declaredAgentUsageCodexModules, [...agentUsageCodexProductionLimits.keys()]),
    "Codex usage facade must declare every production leaf exactly once"
  );
  assert(
    !agentUsageCodexFacadeSource.includes("include!(") &&
      !agentUsageCodexFacadeSource.includes("#[path") &&
      !agentUsageCodexFacadeSource.includes("Connection::open") &&
      !agentUsageCodexFacadeSource.includes("BufReader::new"),
    "Codex usage root must remain an ordinary thin composition facade"
  );
  for (const [relativePath, maxLines] of agentUsageCodexProductionLimits) {
    const source = await readText(relativePath);
    assert(
      sourceLineCount(source) <= maxLines,
      `${relativePath} exceeds its Codex usage responsibility limit (${maxLines} lines maximum)`
    );
    assert(
      !source.includes("include!(") &&
        !source.includes("#[path") &&
        !/^mod [a-z_]+;$/m.test(source),
      `${relativePath} must remain a physical implementation leaf`
    );
  }
  const agentUsageCodexScanSource = await readText(`${agentUsageCodexRoot}/scan.rs`);
  const agentUsageCodexParserSource = await readText(`${agentUsageCodexRoot}/parser.rs`);
  const agentUsageCodexAggregationSource = await readText(
    `${agentUsageCodexRoot}/aggregation.rs`
  );
  assert(
    agentUsageCodexScanSource.includes("CacheBatch::new") &&
      agentUsageCodexScanSource.includes("ParserBatch::new") &&
      agentUsageCodexScanSource.includes("aggregate_cached_usage"),
    "Codex usage orchestration must compose cache, parser, and projection through narrow batches"
  );
  assert(
    agentUsageCodexParserSource.includes("fs::File::open(path)") &&
      !agentUsageCodexParserSource.includes("OpenOptions") &&
      !agentUsageCodexParserSource.includes("write_all"),
    "Codex history parsing must remain local and read-only"
  );
  assert(
    agentUsageCodexAggregationSource.includes('"codex-local-usage-store"') &&
      !agentUsageCodexAggregationSource.includes("to_string_lossy") &&
      !agentUsageCodexAggregationSource.includes("PathBuf"),
    "Codex usage projection must expose aggregate provenance without local paths"
  );
  const agentUsageCacheIntegrationRoot =
    "crates/lico-client-native/tests/agent_usage_cache_cases";
  const agentUsageCacheScenarioLimits = new Map([
    [`${agentUsageCacheIntegrationRoot}/append_refresh.rs`, 190],
    [`${agentUsageCacheIntegrationRoot}/cache_runtime.rs`, 130],
    [`${agentUsageCacheIntegrationRoot}/dedup_lineage.rs`, 170],
    [`${agentUsageCacheIntegrationRoot}/estimates.rs`, 75],
    [`${agentUsageCacheIntegrationRoot}/generic_usage.rs`, 145],
    [`${agentUsageCacheIntegrationRoot}/reconciliation.rs`, 40],
    [`${agentUsageCacheIntegrationRoot}/retained_reports.rs`, 80],
    [`${agentUsageCacheIntegrationRoot}/support.rs`, 115],
    [`${agentUsageCacheIntegrationRoot}/windows.rs`, 80]
  ]);
  const agentUsageCacheIntegrationFacade = await readText(
    "crates/lico-client-native/tests/agent_usage_incremental_cache.rs"
  );
  const agentUsageCacheIntegrationComposition = await readText(
    `${agentUsageCacheIntegrationRoot}/mod.rs`
  );
  assert(
    agentUsageCacheIntegrationFacade.trim() === "mod agent_usage_cache_cases;",
    "Codex usage integration target must remain a one-module facade"
  );
  const declaredAgentUsageCacheScenarios = [...agentUsageCacheIntegrationComposition
    .matchAll(/^mod ([a-z_]+);$/gm)]
    .map((match) => `${agentUsageCacheIntegrationRoot}/${match[1]}.rs`);
  assert(
    sameSet(
      declaredAgentUsageCacheScenarios,
      [...agentUsageCacheScenarioLimits.keys()]
    ),
    "Codex usage integration composition must declare every precise scenario and support leaf"
  );
  const discoveredAgentUsageCacheScenarios = (
    await collectSourceFiles(agentUsageCacheIntegrationRoot, ".rs")
  ).filter((relativePath) => !relativePath.endsWith("/mod.rs"));
  assert(
    sameSet(
      discoveredAgentUsageCacheScenarios,
      [...agentUsageCacheScenarioLimits.keys()]
    ),
    "Codex usage integration directory must not retain hidden or orphaned scenario leaves"
  );
  for (const [relativePath, maxLines] of agentUsageCacheScenarioLimits) {
    const source = await readText(relativePath);
    assert(
      sourceLineCount(source) <= maxLines,
      `${relativePath} exceeds its Codex usage scenario limit (${maxLines} lines maximum)`
    );
    assert(
      !source.includes("include!(") && !source.includes("#[path"),
      `${relativePath} must remain an ordinary integration-test leaf`
    );
  }

  const contentCryptoFacadeSource = await readText(
    "crates/lico-client-native/src/core/secure_mesh_crypto.rs"
  );
  assert(
    !contentCryptoFacadeSource.includes("impl ContentKey") &&
      !contentCryptoFacadeSource.includes("mod tests {") &&
      !contentCryptoFacadeSource.includes("#[path"),
    "content crypto root must expose only ordinary modules and stable restricted re-exports"
  );
  const secureMeshMobileFfiFacadeSource = await readText(
    "crates/lico-client-native/src/ffi/secure_mesh_mobile_ffi.rs"
  );
  assert(
    !secureMeshMobileFfiFacadeSource.includes("match action") &&
      !secureMeshMobileFfiFacadeSource.includes("mod tests {") &&
      !secureMeshMobileFfiFacadeSource.includes("#[path") &&
      secureMeshMobileFfiFacadeSource.includes("mod action_catalog;") &&
      secureMeshMobileFfiFacadeSource.includes("mod dispatch_router;") &&
      secureMeshMobileFfiFacadeSource.includes("pub use feature_status::"),
    "mobile Secure Mesh FFI root must expose only ordinary modules and stable restricted re-exports"
  );
  const secureMeshMobileFfiRoot =
    "crates/lico-client-native/src/ffi/secure_mesh_mobile_ffi";
  const secureMeshMobileFfiFoundationSource = await readJoinedText([
    `${secureMeshMobileFfiRoot}/action_catalog.rs`,
    `${secureMeshMobileFfiRoot}/protected_operation.rs`,
    `${secureMeshMobileFfiRoot}/redacted_error.rs`,
    `${secureMeshMobileFfiRoot}/request_validation.rs`
  ]);
  for (const dependency of [
    "dispatch_context::",
    "dispatch_router::",
    "feature_status::",
    "fixture_envelope::",
    "fixture_file::",
    "fixture_lifecycle::",
    "fixture_payload::",
    "fixture_trust::"
  ]) {
    assert(
      !secureMeshMobileFfiFoundationSource.includes(dependency),
      `mobile FFI action and validation foundations must not depend on ${dependency}`
    );
  }
  const secureMeshMobileFfiFixtureSource = await readJoinedText([
    `${secureMeshMobileFfiRoot}/fixture_envelope.rs`,
    `${secureMeshMobileFfiRoot}/fixture_file.rs`,
    `${secureMeshMobileFfiRoot}/fixture_lifecycle.rs`,
    `${secureMeshMobileFfiRoot}/fixture_payload.rs`,
    `${secureMeshMobileFfiRoot}/fixture_trust.rs`
  ]);
  assert(
    !secureMeshMobileFfiFixtureSource.includes("android_ffi") &&
      !secureMeshMobileFfiFixtureSource.includes("ios_ffi"),
    "mobile Secure Mesh fixtures must remain shared Rust authority without platform bridge dependencies"
  );
  const secureMeshMobileAndroidBridgeSource = await readText(
    "crates/lico-client-native/src/ffi/android_ffi.rs"
  );
  const secureMeshMobileIosBridgeSource = await readText(
    "crates/lico-client-native/src/ffi/ios_ffi.rs"
  );
  for (const [platform, source] of [
    ["Android", secureMeshMobileAndroidBridgeSource],
    ["iOS", secureMeshMobileIosBridgeSource]
  ]) {
    assert(
      source.includes("secure_mesh_mobile_ffi::runtime_self_test") &&
        source.includes("secure_mesh_mobile_ffi::runtime_feature_flags") &&
        source.includes("secure_mesh_mobile_ffi::runtime_protocol_hash") &&
        source.includes("secure_mesh_mobile_ffi::dispatch_json_with_files_dir") &&
        !source.includes("ChaCha20Poly1305") &&
        !source.includes("Hkdf::<") &&
        !source.includes("ContentKey::from_bytes"),
      `${platform} Secure Mesh FFI must delegate shared runtime and cryptographic authority to Rust`
    );
  }
  const contentCryptoFoundationSource = await readJoinedText([
    "crates/lico-client-native/src/core/secure_mesh_crypto/constants.rs",
    "crates/lico-client-native/src/core/secure_mesh_crypto/content_key.rs",
    "crates/lico-client-native/src/core/secure_mesh_crypto/model.rs",
    "crates/lico-client-native/src/core/secure_mesh_crypto/length_codec.rs",
    "crates/lico-client-native/src/core/secure_mesh_crypto/validation.rs"
  ]);
  for (const dependency of [
    "aad_binding::",
    "frame_codec::",
    "header_codec::",
    "key_derivation::",
    "padding::",
    "private_context::",
    "public_payload::"
  ]) {
    assert(
      !contentCryptoFoundationSource.includes(dependency),
      `content crypto constants, keys, models, and validation must not depend on ${dependency}`
    );
  }
  const contentCryptoCodecSource = await readJoinedText([
    "crates/lico-client-native/src/core/secure_mesh_crypto/frame_codec.rs",
    "crates/lico-client-native/src/core/secure_mesh_crypto/header_codec.rs",
    "crates/lico-client-native/src/core/secure_mesh_crypto/padding.rs"
  ]);
  for (const dependency of ["private_context::", "public_payload::"]) {
    assert(
      !contentCryptoCodecSource.includes(dependency),
      `content crypto frame, header, and padding codecs must not depend on ${dependency}`
    );
  }

  return { secureMeshMobileFfiRoot };
}
