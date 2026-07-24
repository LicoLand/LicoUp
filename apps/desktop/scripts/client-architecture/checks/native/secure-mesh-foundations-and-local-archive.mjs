export async function checkSecureMeshFoundationsAndLocalArchive(context) {
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
  const mlKemBraidFacadeSource = await readText(
    "crates/licoup-native/src/core/secure_mesh_mlkem_braid.rs"
  );
  assert(
    !mlKemBraidFacadeSource.includes("impl MlKemBraidSession") &&
      !mlKemBraidFacadeSource.includes("mod tests {") &&
      !mlKemBraidFacadeSource.includes("#[path"),
    "ML-KEM Braid root must expose only ordinary modules and stable re-exports"
  );
  const mlKemBraidFoundationSource = await readJoinedText([
    "crates/licoup-native/src/core/secure_mesh_mlkem_braid/constants.rs",
    "crates/licoup-native/src/core/secure_mesh_mlkem_braid/wire.rs",
    "crates/licoup-native/src/core/secure_mesh_mlkem_braid/output.rs",
    "crates/licoup-native/src/core/secure_mesh_mlkem_braid/secret.rs",
    "crates/licoup-native/src/core/secure_mesh_mlkem_braid/authenticator.rs",
    "crates/licoup-native/src/core/secure_mesh_mlkem_braid/erasure_gf.rs",
    "crates/licoup-native/src/core/secure_mesh_mlkem_braid/erasure_encoder.rs",
    "crates/licoup-native/src/core/secure_mesh_mlkem_braid/erasure_decoder.rs",
    "crates/licoup-native/src/core/secure_mesh_mlkem_braid/encapsulation_kdf.rs"
  ]);
  for (const token of [
    "protocol_state::",
    "send_transition::",
    "receive_transition::",
    "session::",
    "persistence::"
  ]) {
    assert(
      !mlKemBraidFoundationSource.includes(token),
      `ML-KEM Braid wire, crypto, and erasure foundations must not depend on ${token}`
    );
  }
  const mlKemBraidTransitionSource = await readJoinedText([
    "crates/licoup-native/src/core/secure_mesh_mlkem_braid/protocol_state.rs",
    "crates/licoup-native/src/core/secure_mesh_mlkem_braid/transition.rs",
    "crates/licoup-native/src/core/secure_mesh_mlkem_braid/send_transition.rs",
    "crates/licoup-native/src/core/secure_mesh_mlkem_braid/receive_transition.rs"
  ]);
  for (const token of ["session::", "persistence::", "validation::"]) {
    assert(
      !mlKemBraidTransitionSource.includes(token),
      `ML-KEM Braid transition layer must not depend on ${token}`
    );
  }

  const pairwisePersistenceFacadeSource = await readText(
    "crates/licoup-native/src/core/secure_mesh_pairwise/persistence.rs"
  );
  assert(
    !pairwisePersistenceFacadeSource.includes("impl SecureMeshPairwiseDurableStore") &&
      !pairwisePersistenceFacadeSource.includes("mod tests {") &&
      !pairwisePersistenceFacadeSource.includes("#[path"),
    "pairwise persistence root must expose only ordinary modules and stable re-exports"
  );
  const pairwisePersistenceFoundationSource = await readJoinedText([
    "crates/licoup-native/src/core/secure_mesh_pairwise/persistence/store_model.rs",
    "crates/licoup-native/src/core/secure_mesh_pairwise/persistence/public_snapshot.rs",
    "crates/licoup-native/src/core/secure_mesh_pairwise/persistence/secret_snapshot.rs",
    "crates/licoup-native/src/core/secure_mesh_pairwise/persistence/namespace_binding.rs",
    "crates/licoup-native/src/core/secure_mesh_pairwise/persistence/replay_watermark.rs",
    "crates/licoup-native/src/core/secure_mesh_pairwise/persistence/restoration_validation.rs"
  ]);
  for (const dependency of [
    "initial_write::",
    "revocation::",
    "schema::",
    "secret_cleanup::",
    "secret_store_io::",
    "session_commit::",
    "session_read::",
    "store_open::"
  ]) {
    assert(
      !pairwisePersistenceFoundationSource.includes(dependency),
      `pairwise persistence models and validation foundations must not depend on ${dependency}`
    );
  }

  const conversationArchiveJobFiles = (await collectSourceFiles(
    "crates/licoup-native/src/domain/conversation_archive_jobs",
    ".rs"
  )).filter((relativePath) => !relativePath.includes("/tests/"));
  const conversationArchiveJobsRustSource = await readJoinedText([
    "crates/licoup-native/src/domain/conversation_archive_jobs.rs",
    ...conversationArchiveJobFiles
  ]);
  assert(
    conversationArchiveJobsRustSource.includes("local_path_from_user_input") &&
      conversationArchiveJobsRustSource.includes("not a URI") &&
      conversationArchiveJobsRustSource.includes("not a network share") &&
      conversationArchiveJobsRustSource.includes("ActivityLog"),
    "conversation archive jobs must keep explicit local-path and local-activity boundaries"
  );
  for (const token of ["reqwest::", "ureq::", "TcpStream", "UdpSocket"]) {
    assert(
      !conversationArchiveJobsRustSource.includes(token),
      `conversation archive jobs must not add a network transfer path via ${token}`
    );
  }

  const relayEnvelopeFiles = (await collectSourceFiles(
    "crates/licoup-native/src/core/secure_mesh_relay_envelope",
    ".rs"
  )).filter((relativePath) => !relativePath.includes("/tests/"));
  const relayEnvelopeRustSource = await readJoinedText([
    "crates/licoup-native/src/core/secure_mesh_relay_envelope.rs",
    ...relayEnvelopeFiles
  ]);
  for (const token of [
    "Hkdf::<Sha256>",
    "XChaCha20Poly1305",
    ".ct_eq(",
    "Zeroizing",
    "candidate-key limit exceeded",
    "deny_unknown_fields",
    "validate_authenticated_padding_bucket",
    "MAX_RELAY_ENVELOPE_JSON_BYTES",
    "RELAY_HEADER_FRAME_MAGIC",
    "OUTER_AAD_MAGIC"
  ]) {
    assert(
      relayEnvelopeRustSource.includes(token),
      `relay envelope split must preserve cryptographic and bounded-codec evidence: ${token}`
    );
  }
  assert(
    !/(^|[^A-Za-z])ChaCha20Poly1305::new/u.test(relayEnvelopeRustSource) &&
      !relayEnvelopeRustSource.includes("LCOSM-PAIRWISE-RELAY-v1"),
    "relay envelope production code must not restore a pre-migration header cipher or legacy AAD"
  );

}
