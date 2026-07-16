export async function checkTargetReadinessReducer(context) {
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
  // Target catalog and merge policy must share one readiness reducer.
  const targetSourceFiles = [
    "crates/lico-client-native/src/domain/targets.rs",
    ...await collectSourceFiles("crates/lico-client-native/src/domain/targets", ".rs")
  ];
  const targetsSource = await readJoinedText(targetSourceFiles);
  const targetCatalogSource = await readText(
    "crates/lico-client-native/src/domain/targets/catalog.rs"
  );
  const targetScanMergeSource = await readText(
    "crates/lico-client-native/src/domain/targets/scan_merge.rs"
  );
  const supportsApplyMatches = targetCatalogSource.match(/matches!\([\s\S]*?"openclaw".*?"kilo-code"\)/);
  assert(supportsApplyMatches === null,
    "target catalog must not contain a duplicate supports_apply list; use adapter_capabilities_for or adapter_supports_action"
  );
  assert(targetCatalogSource.includes("fn target_supports_skill_install") &&
    targetCatalogSource.includes("fn adapter_capabilities_for"),
    "target catalog must own the unified adapter capability policy"
  );
  assert(targetCatalogSource.includes("fn candidate_runtime_is_ready") &&
    targetCatalogSource.includes("runtime_driver_profile") &&
    targetCatalogSource.includes('profile.readiness != "ready"') &&
    targetCatalogSource.includes("runtime_evidence_matches") &&
    targetCatalogSource.includes('conversation_readiness = "ready"') &&
    targetCatalogSource.includes('conversation_readiness = "unverified"') &&
    targetScanMergeSource.includes("candidate_runtime_is_ready(") &&
    targetScanMergeSource.includes('push("runtime.message.send".to_string())'),
    "target discovery and candidate merging must advertise runtime.message.send only through the shared readiness evidence gate"
  );
  const targetRuntimeBindingSource = await readText(
    "crates/lico-client-native/src/domain/targets/runtime_binding.rs"
  );
  assert(targetsSource.includes("ready_runtime_executable") &&
    targetRuntimeBindingSource.includes("runtime_driver_profile") &&
    targetRuntimeBindingSource.includes('Some("runtime.message.send")') &&
    targetRuntimeBindingSource.includes("fs::canonicalize") &&
    targetRuntimeBindingSource.includes("runtime_evidence_matches"),
    "runtime.message.send must require canonical readiness and an exact local executable binding"
  );
  const targetCandidateSource = await readText("apps/desktop/lib/src/contracts/target_candidate.dart");
  assert(targetCandidateSource.includes("conversationReadiness == 'ready'") &&
    targetCandidateSource.includes("supportsAction('runtime.message.send')"),
    "desktop runtime sending must require both reducer-owned ready and the advertised action"
  );

}
