const rustCliRoot = "crates/licoup-native/src";

export async function checkProductContractsAndPortableData(context, { modules }) {
  const { assert, sameSet } = context;
  const portableDirs = modules["portable-data"]?.portableDirectories || [];
  const expectedPortableDirs = [
    "licoup",
    "licoup/settings",
    "licoup/targets",
    "licoup/pairings",
    "licoup/skills",
    "licoup/pins",
    "licoup/mobile-relay",
    "licoup/activity",
    "licoup/snapshots"
  ];
  assert(sameSet([...portableDirs].sort(), [...expectedPortableDirs].sort()),
    "portable-data module must list exactly the current portable runtime directories");

}

export async function checkFileSecurityAndClientState(context) {
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
  const fileSecurityRoot = "crates/licoup-foundation/src/platform/file_security";
  const fileSecurityLeaves = [
    "append_lock.rs",
    "atomic_replace.rs",
    "hardening.rs",
    "marker.rs",
    "policy.rs",
    "sync.rs",
    "unix_hardening.rs",
    "validation.rs",
    "windows_acl.rs"
  ];
  const fileSecurityFacadeSource = await readText(`${fileSecurityRoot}.rs`);
  const fileSecurityFiles = await collectSourceFiles(fileSecurityRoot, ".rs");
  const fileSecurityProductionFiles = fileSecurityFiles.filter(
    (relativePath) => !relativePath.includes("/tests/")
  );
  assert(
    sameSet(
      fileSecurityProductionFiles,
      fileSecurityLeaves.map((leaf) => `${fileSecurityRoot}/${leaf}`)
    ) &&
      fileSecurityLeaves.every((leaf) =>
        fileSecurityFacadeSource.includes(`mod ${leaf.replace(".rs", "")};`)) &&
      !fileSecurityFacadeSource.includes("fn ") &&
      !fileSecurityFacadeSource.includes("OpenOptions") &&
      !fileSecurityFacadeSource.includes("include!(") &&
      !fileSecurityFacadeSource.includes("#[path"),
    "File security root must remain an exact thin stable facade"
  );
  const fileSecuritySources = Object.fromEntries(await Promise.all(
    fileSecurityLeaves.map(async (leaf) => [
      leaf,
      await readText(`${fileSecurityRoot}/${leaf}`)
    ])
  ));
  for (const leaf of ["policy.rs", "sync.rs", "unix_hardening.rs", "windows_acl.rs"]) {
    assert(
      !fileSecuritySources[leaf].includes("super::"),
      `${leaf} must remain an independent file-security foundation or platform policy`
    );
  }
  assert(
    !fileSecuritySources["unix_hardening.rs"].includes("windows_acl") &&
      !fileSecuritySources["windows_acl.rs"].includes("unix_hardening"),
    "Unix hardening and Windows ACL policy must not depend on each other"
  );
  for (const dependency of [
    "super::append_lock",
    "super::atomic_replace",
    "super::hardening",
    "super::marker"
  ]) {
    assert(
      !fileSecuritySources["validation.rs"].includes(dependency),
      `File security validation must not depend on ${dependency}`
    );
  }
  assert(
    fileSecuritySources["append_lock.rs"].includes("FlockArg::LockExclusive") &&
      fileSecuritySources["append_lock.rs"].includes("O_NOFOLLOW") &&
      fileSecuritySources["append_lock.rs"].includes("PRIVATE_APPEND_FILE_MAX_BYTES") &&
      fileSecuritySources["atomic_replace.rs"].includes("ErrorKind::CrossesDevices") &&
      fileSecuritySources["atomic_replace.rs"].includes("copy_cross_device_then_atomic_replace") &&
      fileSecuritySources["atomic_replace.rs"].includes("validate_private_path_ancestors") &&
      fileSecuritySources["marker.rs"].includes("saturating_add(1)") &&
      fileSecuritySources["validation.rs"].includes("symlink_metadata") &&
      fileSecuritySources["validation.rs"].includes("ensure_same_file") &&
      fileSecuritySources["hardening.rs"].includes("private tree contains a symbolic link") &&
      fileSecuritySources["sync.rs"].includes("sync_all()") &&
      fileSecuritySources["windows_acl.rs"].includes("stderr(Stdio::null())"),
    "File security leaves must retain bounded append, atomic commit, no-follow validation, durable sync, and private ACL evidence"
  );
  const fileSecurityProductionSource = Object.values(fileSecuritySources).join("\n");
  for (const forbidden of ["unsafe {", ".display()", "output.stderr", "include!(", "#[path"]) {
    assert(
      !fileSecurityProductionSource.includes(forbidden),
      `File security production leaves must not expose unsafe or sensitive implementation detail via ${forbidden}`
    );
  }
  const fileSecurityInternalImport =
    /file_security::(?:append_lock|atomic_replace|hardening|marker|policy|sync|unix_hardening|validation|windows_acl)/u;
  for (const relativePath of (await collectSourceFiles(rustCliRoot, ".rs")).filter(
    (sourcePath) => sourcePath !== `${fileSecurityRoot}.rs` &&
      !sourcePath.startsWith(`${fileSecurityRoot}/`)
  )) {
    assert(
      !fileSecurityInternalImport.test(await readText(relativePath)),
      `${relativePath} must consume file security only through its stable facade`
    );
  }

  // The persistence owners live in `licoup-client-state`; the command layer
  // keeps a thin facade plus the one module that depends on the wire contract.
  const clientStateOwnerRoot = "crates/licoup-client-state/src";
  const clientStateRoot = "crates/licoup-native/src/platform/client_state";
  const clientStateCommandLeaves = ["operations.rs"];
  const clientStateLeaves = [
    "accessors.rs",
    "activity.rs",
    "collections.rs",
    "migration.rs",
    "paths.rs",
    "policy.rs",
    "redaction.rs",
    "resource_policy.rs",
    "serialization.rs",
    "snapshots.rs"
  ];
  // The bounded resource policy is a module directory inside the same owner,
  // so its four leaves are production files of this crate too.
  const clientStateModuleLeaves = [
    "resource_bounds/mod.rs",
    "resource_bounds/policy.rs",
    "resource_bounds/history.rs",
    "resource_bounds/search.rs"
  ];
  const clientStateModules = ["resource_bounds"];
  const clientStateFacadeSource = await readText(`${clientStateOwnerRoot}/lib.rs`);
  const clientStateCommandFacadeSource = await readText(`${clientStateRoot}.rs`);
  const clientStateFiles = await collectSourceFiles(clientStateOwnerRoot, ".rs");
  const clientStateProductionFiles = clientStateFiles.filter(
    (relativePath) => !relativePath.includes("/tests/")
  );
  assert(
    sameSet(
      clientStateProductionFiles,
      ["lib.rs", ...clientStateLeaves, ...clientStateModuleLeaves].map(
        (leaf) => `${clientStateOwnerRoot}/${leaf}`
      )
    ) &&
      [
        ...clientStateLeaves.map((leaf) => leaf.replace(".rs", "")),
        ...clientStateModules
      ].every((name) => clientStateFacadeSource.includes(`mod ${name};`)) &&
      !clientStateFacadeSource.includes("struct ") &&
      !clientStateFacadeSource.includes("impl ") &&
      !clientStateFacadeSource.includes("fn ") &&
      !clientStateFacadeSource.includes("include!(") &&
      !clientStateFacadeSource.includes("#[path"),
    "Client state owner crate must remain an exact thin stable facade"
  );
  assert(
    sameSet(
      (await collectSourceFiles(clientStateRoot, ".rs")).filter(
        (relativePath) => !relativePath.includes("/tests/")
      ),
      clientStateCommandLeaves.map((leaf) => `${clientStateRoot}/${leaf}`)
    ) &&
      clientStateCommandLeaves.every((leaf) =>
        clientStateCommandFacadeSource.includes(`mod ${leaf.replace(".rs", "")};`)) &&
      !clientStateCommandFacadeSource.includes("struct ") &&
      !clientStateCommandFacadeSource.includes("impl ") &&
      !clientStateCommandFacadeSource.includes("fn ") &&
      !clientStateCommandFacadeSource.includes("include!(") &&
      !clientStateCommandFacadeSource.includes("#[path"),
    "Client state command layer must keep only the wire contract operations module"
  );
  const clientStateSources = Object.fromEntries(await Promise.all(
    [...clientStateLeaves, ...clientStateModuleLeaves].map(async (leaf) => [
      leaf,
      await readText(`${clientStateOwnerRoot}/${leaf}`)
    ])
  ));
  for (const [leaf, owner, foreignOwners] of [
    ["collections.rs", "struct ClientStateStore", ["ActivityLog", "SnapshotStore"]],
    ["activity.rs", "struct ActivityLog", ["ClientStateStore", "SnapshotStore"]],
    ["snapshots.rs", "struct SnapshotStore", ["ClientStateStore", "ActivityLog"]]
  ]) {
    assert(
      clientStateSources[leaf].includes(owner) &&
        foreignOwners.every((foreign) => !clientStateSources[leaf].includes(foreign)),
      `${leaf} must remain an independent single-path client-state owner`
    );
  }
  assert(
    clientStateSources["accessors.rs"].includes("impl ClientStateStore") &&
      clientStateSources["accessors.rs"].includes("ActivityLog::from_state_root") &&
      clientStateSources["accessors.rs"].includes("SnapshotStore::from_state_root"),
    "Client state compatibility accessors must derive owners without transitive storage"
  );
  assert(
    clientStateSources["activity.rs"].includes("VecDeque") &&
    clientStateSources["activity.rs"].includes("policy::MAX_ACTIVITY_EVENT_BYTES") &&
      clientStateSources["activity.rs"].includes("policy::MAX_ACTIVITY_EVENTS") &&
      clientStateSources["activity.rs"].includes("open_private_text_bounded") &&
      clientStateSources["activity.rs"].includes("redaction::redact_activity_payload") &&
      clientStateSources["activity.rs"].includes("Read::by_ref(&mut reader)") &&
      !clientStateSources["activity.rs"].includes("display_path"),
    "ActivityLog must keep bounded latest-window JSONL reads and privacy projection"
  );
  assert(
    clientStateSources["snapshots.rs"].includes("MAX_SNAPSHOT_SOURCE_BYTES") &&
      clientStateSources["snapshots.rs"].includes("MAX_SNAPSHOT_RECORD_BYTES") &&
      clientStateSources["snapshots.rs"].includes("MAX_SNAPSHOT_FILES") &&
      clientStateSources["snapshots.rs"].includes("redact_snapshot") &&
      clientStateSources["snapshots.rs"].includes('"sourcePath": paths::redacted_local_path()') &&
      clientStateSources["paths.rs"].includes("snapshot_id.starts_with(\"snapshot-\")") &&
      clientStateSources["paths.rs"].includes("validate_private_path_ancestors") &&
      clientStateSources["paths.rs"].includes("O_NOFOLLOW") &&
      clientStateSources["paths.rs"].includes("ensure_same_file"),
    "SnapshotStore must keep bounded capture, redacted projection, safe IDs, and no-follow TOCTOU validation"
  );
  assert(
    clientStateSources["redaction.rs"].includes("OnceLock<Regex>") &&
      clientStateSources["redaction.rs"].includes("MAX_REDACTION_DEPTH") &&
      clientStateSources["redaction.rs"].includes("MAX_REDACTION_PATHS") &&
      clientStateSources["redaction.rs"].includes("REDACTED_PRIVATE_KEY") &&
      clientStateSources["serialization.rs"].includes("atomic_write_private_text_bounded") &&
      clientStateSources["serialization.rs"].includes("read_private_text_bounded"),
    "Client state redaction and serialization must cache patterns and retain explicit bounds"
  );
  const clientStateProductionSource = [
    ...Object.values(clientStateSources),
    await readText(`${clientStateRoot}/operations.rs`)
  ].join("\n");
  for (const forbidden of [
    "ureq::",
    "reqwest::",
    "TcpStream",
    "UdpSocket",
    "unsafe {"
  ]) {
    assert(
      !clientStateProductionSource.includes(forbidden),
      `Client state must remain local-only and free of network or unsafe runtime authority via ${forbidden}`
    );
  }
  const clientStateInternalImport =
    /client_state::(?:accessors|activity|collections|operations|paths|policy|redaction|serialization|snapshots)::/u;
  for (const relativePath of (await collectSourceFiles(rustCliRoot, ".rs")).filter(
    (sourcePath) => sourcePath !== `${clientStateRoot}.rs` &&
      !sourcePath.startsWith(`${clientStateRoot}/`)
  )) {
    assert(
      !clientStateInternalImport.test(await readText(relativePath)),
      `${relativePath} must consume client state only through its stable facade`
    );
  }

}
