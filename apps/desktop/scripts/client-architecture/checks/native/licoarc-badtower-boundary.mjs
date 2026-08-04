export async function checkLicoArcBadTowerBoundary(context) {
  const { assert, readText } = context;
  const stationRoot = "crates/licoup-native/src/platform/badtower_station";
  const stationLeaves = ["contract.rs", "http_io.rs", "transport.rs", "wire.rs"];
  const stationSources = Object.fromEntries(await Promise.all(
    stationLeaves.map(async (leaf) => [
      leaf,
      await readText(`${stationRoot}/${leaf}`),
    ]),
  ));
  const stationFacade = await readText(`${stationRoot}/mod.rs`);
  const urlSecurity = await readText(
    "crates/licoup-native/src/platform/url_security.rs",
  );
  assert(
    stationLeaves.every((leaf) =>
      stationFacade.includes(`mod ${leaf.replace(".rs", "")};`)) &&
      stationFacade.includes(
        "pub(crate) use transport::BadTowerStationTransport;",
      ),
    "BadTower station adapter must expose one crate-private split module root",
  );
  assert(
    stationSources["contract.rs"].includes("enum BadTowerStationOperation") &&
      stationSources["contract.rs"].includes("struct BadTowerStationError") &&
      stationSources["contract.rs"].includes("MAX_RECEIVE_RESPONSE_BYTES") &&
      stationSources["transport.rs"].includes("lease_mailbox") &&
      stationSources["transport.rs"].includes("send_envelope") &&
      stationSources["transport.rs"].includes("receive_envelopes") &&
      stationSources["transport.rs"].includes("delete_envelope") &&
      stationSources["transport.rs"].includes(".validate()") &&
      stationSources["transport.rs"].includes("envelope.to_json()") &&
      stationSources["wire.rs"].includes("deny_unknown_fields") &&
      !stationSources["transport.rs"].includes("plaintext"),
    "BadTower station adapter must keep an exact four-operation ciphertext-only surface",
  );
  assert(
    stationLeaves.filter((leaf) =>
      stationSources[leaf].includes("ureq::")).join(",") === "http_io.rs" &&
      stationSources["transport.rs"].includes(
        "canonical_https_or_loopback_http_origin",
      ) &&
      urlSecurity.includes('"https" =>') &&
      urlSecurity.includes('"http"') &&
      urlSecurity.includes("if is_exact_loopback_host") &&
      stationSources["http_io.rs"].includes(
        "Duration::from_secs(HTTP_TIMEOUT_SECONDS)",
      ) &&
      stationSources["http_io.rs"].includes("MAX_ERROR_RESPONSE_BYTES") &&
      stationSources["http_io.rs"].includes(".take(take_limit)") &&
      stationSources["contract.rs"].includes("TransportOutcomeUnknown"),
    "BadTower station adapter must isolate TLS-gated bounded egress and redact server detail",
  );

  const acceptance = await readText(
    "tools/scripts/lib/licoarc-badtower-acceptance-report.mjs",
  );
  assert(
    acceptance.includes("freshEndpointCount") &&
      acceptance.includes("positiveExchange") &&
      acceptance.includes("roundTrip") &&
      acceptance.includes("stationPlaintextAbsent") &&
      acceptance.includes("nonConformantEnvelopeRejected") &&
      acceptance.includes("transportHintsNonAuthoritative") &&
      acceptance.includes("exactFiveOuterFields"),
    "Lico Arc BadTower acceptance must require a redacted real two-endpoint boundary",
  );
}
