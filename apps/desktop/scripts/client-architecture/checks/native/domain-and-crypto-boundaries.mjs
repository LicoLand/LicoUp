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
  } = context;
  const clientUpdateRoot = "crates/licoup-native/src/domain/client_update";
  const clientUpdateFacadeSource = await readText(`${clientUpdateRoot}.rs`);
  const clientUpdateDeclaredModules = [...clientUpdateFacadeSource
    .matchAll(/^mod ([a-z_]+);$/gm)]
    .map((match) => match[1])
    .filter((moduleName) => moduleName !== "tests");
  assert(
    sameSet(clientUpdateDeclaredModules, [
      "apply",
      "archive",
      "canonical",
      "check",
      "constants",
      "dispatch",
      "download",
      "github_source",
      "keys",
      "metadata",
      "model",
      "native_runner",
      "params",
      "release",
      "revocation",
      "selection",
      "signature",
      "staging",
      "status",
      "tree",
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
    "native_runner::",
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
    `${clientUpdateRoot}/native_runner/mod.rs`,
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
      "archive.rs",
      "artifact_binding.rs",
      "github_source.rs",
      "native_runner.rs",
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
    "crates/licoup-native/src/domain/agent_usage/agent_usage_codex";
  const agentUsageCodexProductionLeaves = new Set([
    `${agentUsageCodexRoot}/aggregation.rs`,
    `${agentUsageCodexRoot}/append_guard.rs`,
    `${agentUsageCodexRoot}/cache.rs`,
    `${agentUsageCodexRoot}/cache_batch.rs`,
    `${agentUsageCodexRoot}/cache_cleanup.rs`,
    `${agentUsageCodexRoot}/constants.rs`,
    `${agentUsageCodexRoot}/event_hash.rs`,
    `${agentUsageCodexRoot}/file_collection.rs`,
    `${agentUsageCodexRoot}/lineage.rs`,
    `${agentUsageCodexRoot}/model_backfill.rs`,
    `${agentUsageCodexRoot}/models.rs`,
    `${agentUsageCodexRoot}/parser.rs`,
    `${agentUsageCodexRoot}/rollup.rs`,
    `${agentUsageCodexRoot}/scan.rs`,
    `${agentUsageCodexRoot}/scan_params.rs`,
    `${agentUsageCodexRoot}/utils.rs`,
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
      [...agentUsageCodexProductionLeaves]
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
    sameSet(declaredAgentUsageCodexModules, [...agentUsageCodexProductionLeaves]),
    "Codex usage facade must declare every production leaf exactly once"
  );
  assert(
    !agentUsageCodexFacadeSource.includes("include!(") &&
      !agentUsageCodexFacadeSource.includes("#[path") &&
      !agentUsageCodexFacadeSource.includes("Connection::open") &&
      !agentUsageCodexFacadeSource.includes("BufReader::new"),
    "Codex usage root must remain an ordinary thin composition facade"
  );
  for (const relativePath of agentUsageCodexProductionLeaves) {
    const source = await readText(relativePath);
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
    "crates/licoup-native/tests/agent_usage_cache_cases";
  const agentUsageCacheScenarioLeaves = new Set([
    `${agentUsageCacheIntegrationRoot}/adapter_coverage.rs`,
    `${agentUsageCacheIntegrationRoot}/append_refresh.rs`,
    `${agentUsageCacheIntegrationRoot}/cache_runtime.rs`,
    `${agentUsageCacheIntegrationRoot}/cumulative_resume.rs`,
    `${agentUsageCacheIntegrationRoot}/dedup_lineage.rs`,
    `${agentUsageCacheIntegrationRoot}/fallback_coverage.rs`,
    `${agentUsageCacheIntegrationRoot}/generic_usage.rs`,
    `${agentUsageCacheIntegrationRoot}/native_rollup.rs`,
    `${agentUsageCacheIntegrationRoot}/reconciliation.rs`,
    `${agentUsageCacheIntegrationRoot}/retained_reports.rs`,
    `${agentUsageCacheIntegrationRoot}/support.rs`,
    `${agentUsageCacheIntegrationRoot}/windows.rs`,
  ]);
  const agentUsageCacheIntegrationFacade = await readText(
    "crates/licoup-native/tests/agent_usage_incremental_cache.rs"
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
      [...agentUsageCacheScenarioLeaves]
    ),
    "Codex usage integration composition must declare every precise scenario and support leaf"
  );
  const discoveredAgentUsageCacheScenarios = (
    await collectSourceFiles(agentUsageCacheIntegrationRoot, ".rs")
  ).filter((relativePath) => !relativePath.endsWith("/mod.rs"));
  assert(
    sameSet(
      discoveredAgentUsageCacheScenarios,
      [...agentUsageCacheScenarioLeaves]
    ),
    "Codex usage integration directory must not retain hidden or orphaned scenario leaves"
  );
  for (const relativePath of agentUsageCacheScenarioLeaves) {
    const source = await readText(relativePath);
    assert(
      !source.includes("include!(") && !source.includes("#[path"),
      `${relativePath} must remain an ordinary integration-test leaf`
    );
  }

  const contentCryptoFacadeSource = await readText(
    "crates/licoup-native/src/core/secure_mesh_crypto.rs"
  );
  assert(
    !contentCryptoFacadeSource.includes("impl ContentKey") &&
      !contentCryptoFacadeSource.includes("mod tests {") &&
      !contentCryptoFacadeSource.includes("#[path"),
    "content crypto root must expose only ordinary modules and stable restricted re-exports"
  );
  const secureMeshMobileFfiFacadeSource = await readText(
    "crates/licoup-native/src/ffi/secure_mesh_mobile_ffi.rs"
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
    "crates/licoup-native/src/ffi/secure_mesh_mobile_ffi";
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
    "crates/licoup-native/src/ffi/android_ffi.rs"
  );
  const secureMeshMobileIosBridgeSource = await readText(
    "crates/licoup-native/src/ffi/ios_ffi.rs"
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
    "crates/licoup-native/src/core/secure_mesh_crypto/constants.rs",
    "crates/licoup-native/src/core/secure_mesh_crypto/content_key.rs",
    "crates/licoup-native/src/core/secure_mesh_crypto/model.rs",
    "crates/licoup-native/src/core/secure_mesh_crypto/length_codec.rs",
    "crates/licoup-native/src/core/secure_mesh_crypto/validation.rs"
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
    "crates/licoup-native/src/core/secure_mesh_crypto/frame_codec.rs",
    "crates/licoup-native/src/core/secure_mesh_crypto/header_codec.rs",
    "crates/licoup-native/src/core/secure_mesh_crypto/padding.rs"
  ]);
  for (const dependency of ["private_context::", "public_payload::"]) {
    assert(
      !contentCryptoCodecSource.includes(dependency),
      `content crypto frame, header, and padding codecs must not depend on ${dependency}`
    );
  }

  return { secureMeshMobileFfiRoot };
}
