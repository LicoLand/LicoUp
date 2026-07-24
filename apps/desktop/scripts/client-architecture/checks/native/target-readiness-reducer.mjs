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
  // Target catalog and merge policy must share one runtime-availability reducer.
  const targetSourceFiles = [
    "crates/licoup-native/src/domain/targets.rs",
    ...await collectSourceFiles("crates/licoup-native/src/domain/targets", ".rs")
  ];
  const targetsSource = await readJoinedText(targetSourceFiles);
  const targetCatalogSource = await readText(
    "crates/licoup-native/src/domain/targets/catalog.rs"
  );
  const targetScanMergeSource = await readText(
    "crates/licoup-native/src/domain/targets/scan_merge.rs"
  );
  const supportsApplyMatches = targetCatalogSource.match(/matches!\([\s\S]*?"openclaw".*?"kilo-code"\)/);
  assert(supportsApplyMatches === null,
    "target catalog must not contain a duplicate supports_apply list; use adapter_capabilities_for or adapter_supports_action"
  );
  assert(targetCatalogSource.includes("fn target_supports_skill_install") &&
    targetCatalogSource.includes("fn adapter_capabilities_for"),
    "target catalog must own the unified adapter capability policy"
  );
  assert(targetCatalogSource.includes("fn candidate_runtime_is_available") &&
    targetCatalogSource.includes("runtime_driver_profile") &&
    !targetCatalogSource.includes('profile.readiness ==') &&
    !targetCatalogSource.includes('profile.readiness !=') &&
    targetScanMergeSource.includes("candidate_runtime_is_available(") &&
    targetScanMergeSource.includes('push("runtime.message.send".to_string())'),
    "target discovery must advertise runtime.message.send whenever a driver profile and executable are available; parity evidence must stay informational"
  );
  const targetRuntimeBindingSource = await readText(
    "crates/licoup-native/src/domain/targets/runtime_binding.rs"
  );
  assert(targetsSource.includes("available_runtime_executable") &&
    targetRuntimeBindingSource.includes("runtime_driver_profile") &&
    !targetRuntimeBindingSource.includes('profile.readiness') &&
    !targetRuntimeBindingSource.includes('runtime.message.send') &&
    targetRuntimeBindingSource.includes("fs::canonicalize") &&
    !targetRuntimeBindingSource.includes("runtime_evidence_matches"),
    "runtime.message.send must keep an exact single local executable binding without letting projected actions or parity evidence veto execution"
  );
  const targetCandidateSource = await readText("apps/desktop/lib/src/contracts/target_candidate.dart");
  assert(targetCandidateSource.includes("visibleInClient &&") &&
    targetCandidateSource.includes("conversationDriverStatus != 'unsupported'") &&
    !targetCandidateSource.includes("supportsAction('runtime.message.send')") &&
    !targetCandidateSource.includes("conversationReadiness == 'ready'"),
    "desktop runtime sending must use deterministic local binding facts; projected actions and parity evidence stay informational"
  );

}
