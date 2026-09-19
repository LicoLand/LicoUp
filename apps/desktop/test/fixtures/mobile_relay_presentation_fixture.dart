import 'package:riverpod/misc.dart' show Override;

import 'package:licoup/src/presentation/mobile_relay/mobile_relay_inputs.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_projection.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_providers.dart';
import 'package:licoup/src/projections/mobile_relay/mobile_relay_presentation_sources.dart';

import 'mobile_relay_binding_fixture.dart';
import 'presentation_source_fixture.dart';

/// Synthetic mobile relay presentation sources wired as provider overrides
/// for feature widget tests. Region values derive from the existing projection
/// fixture shape so test data setup stays unchanged.
final class MobileRelayPresentationFixture {
  factory MobileRelayPresentationFixture({MobileRelayProjection? projection}) {
    return MobileRelayPresentationFixture._(
      projection ?? mobileRelayProjectionFixture(),
    );
  }

  MobileRelayPresentationFixture._(MobileRelayProjection projection)
    : pairing = PresentationSourceFixture(
        fieldGroup: mobileRelayPairingRegion.fieldGroup,
        initial: pairingOf(projection),
      ),
      trust = PresentationSourceFixture(
        fieldGroup: mobileRelayTrustRegion.fieldGroup,
        initial: trustOf(projection),
      ),
      approvals = PresentationSourceFixture(
        fieldGroup: mobileRelayApprovalsRegion.fieldGroup,
        initial: approvalsOf(projection),
      ),
      transfers = PresentationSourceFixture(
        fieldGroup: mobileRelayTransfersRegion.fieldGroup,
        initial: transfersOf(projection),
      ),
      capabilities = PresentationSourceFixture(
        fieldGroup: mobileRelayCapabilitiesRegion.fieldGroup,
        initial: capabilitiesOf(projection),
      ),
      home = PresentationSourceFixture(
        fieldGroup: mobileRelayHomeRegion.fieldGroup,
        initial: homeOf(projection),
      );

  final PresentationSourceFixture<MobileRelayPairingInputs> pairing;
  final PresentationSourceFixture<MobileRelayTrustInputs> trust;
  final PresentationSourceFixture<MobileRelayApprovalsInputs> approvals;
  final PresentationSourceFixture<MobileRelayTransfersInputs> transfers;
  final PresentationSourceFixture<MobileRelayCapabilitiesInputs> capabilities;
  final PresentationSourceFixture<MobileRelayHomeInputs> home;

  List<Override> get overrides => <Override>[
    mobileRelayPairingSourceProvider.overrideWithValue(pairing),
    mobileRelayTrustSourceProvider.overrideWithValue(trust),
    mobileRelayApprovalsSourceProvider.overrideWithValue(approvals),
    mobileRelayTransfersSourceProvider.overrideWithValue(transfers),
    mobileRelayCapabilitiesSourceProvider.overrideWithValue(capabilities),
    mobileRelayHomeSourceProvider.overrideWithValue(home),
  ];

  /// Republishes the regions derived from one projection fixture value.
  ///
  /// Mirrors the production region sources: a region whose value is unchanged
  /// keeps its installed snapshot, so subscribers of unrelated regions do not
  /// rebuild.
  void publishProjection(MobileRelayProjection projection) {
    _publishIfChanged(pairing, pairingOf(projection));
    _publishIfChanged(trust, trustOf(projection));
    _publishIfChanged(approvals, approvalsOf(projection));
    _publishIfChanged(transfers, transfersOf(projection));
    _publishIfChanged(capabilities, capabilitiesOf(projection));
    _publishIfChanged(home, homeOf(projection));
  }

  static MobileRelayPairingInputs pairingOf(MobileRelayProjection projection) =>
      MobileRelayPairingInputs.fromProjection(projection);

  static MobileRelayTrustInputs trustOf(MobileRelayProjection projection) =>
      MobileRelayTrustInputs.fromProjection(projection);

  static MobileRelayApprovalsInputs approvalsOf(
    MobileRelayProjection projection,
  ) => MobileRelayApprovalsInputs.fromProjection(projection);

  static MobileRelayTransfersInputs transfersOf(
    MobileRelayProjection projection,
  ) => MobileRelayTransfersInputs.fromProjection(projection);

  static MobileRelayCapabilitiesInputs capabilitiesOf(
    MobileRelayProjection projection,
  ) => MobileRelayCapabilitiesInputs.fromProjection(projection);

  static MobileRelayHomeInputs homeOf(MobileRelayProjection projection) =>
      MobileRelayHomeInputs.fromProjection(projection);

  static void _publishIfChanged<T>(
    PresentationSourceFixture<T> region,
    T next,
  ) {
    if (region.value == next) return;
    region.publish(next);
  }

  Future<void> dispose() async {
    await pairing.dispose();
    await trust.dispose();
    await approvals.dispose();
    await transfers.dispose();
    await capabilities.dispose();
    await home.dispose();
  }
}
