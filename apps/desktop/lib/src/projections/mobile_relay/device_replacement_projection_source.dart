import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/presentation/mobile_relay/device_replacement_projection.dart';
import 'package:licoup/src/projections/close_broadcast_controller.dart';

/// The endpoint authority and revocation facts of one device subject.
///
/// The port exists so the projection can be driven without a native owner. The
/// authority that would publish it lives in `crates/licoup-native`
/// (`secret_custody/cleanup_authority.rs` derives the subject; the transparency
/// leaf carries the rotation epoch and directory state) and has no Dart bridge
/// in this tree, so the shipped composition supplies
/// [UnobservedDeviceReplacementInputs] and tests supply their own synthetic
/// input.
abstract interface class DeviceSubjectAuthorityInput {
  DeviceEndpointAuthorityFacts get authority;

  DeviceIdentityRevocationFacts get identityRevocation;

  Stream<void> get changes;
}

/// The verified-commit facts of one transfer.
abstract interface class DeviceTransferVerificationInput {
  DeviceTransferVerificationFacts get verification;

  Stream<void> get changes;
}

/// The local cleanup settlement, its receipt and the replacement's answer.
abstract interface class DeviceCleanupSettlementInput {
  DevicePendingCleanupFacts get settlement;

  Stream<void> get changes;
}

/// The remote work, its stop ownership and its effects.
abstract interface class DeviceRemoteWorkControlInput {
  DeviceRemoteWorkFacts get work;

  Stream<void> get changes;
}

/// The app-only erase review the operator is shown.
abstract interface class DeviceEraseReviewInput {
  DeviceEraseReviewFacts get review;

  Stream<void> get changes;
}

/// Joins the five independent device inputs into one immutable projection.
///
/// The inputs stay separate owners, exactly as they are separate native owners:
/// an authority change publishes a projection whose authority moved and whose
/// transfer, cleanup, remote-work and review facts did not. A restart or a
/// reconnect therefore re-reads five facts rather than one summary, and a change
/// that leaves the projected value equal emits nothing.
final class DeviceReplacementProjectionSource
    implements ProjectionSource<DeviceReplacementProjection> {
  DeviceReplacementProjectionSource({
    required DeviceSubjectAuthorityInput authority,
    required DeviceTransferVerificationInput transferVerification,
    required DeviceCleanupSettlementInput cleanup,
    required DeviceRemoteWorkControlInput remoteWork,
    required DeviceEraseReviewInput eraseReview,
  }) : _authority = authority,
       _transferVerification = transferVerification,
       _cleanup = cleanup,
       _remoteWork = remoteWork,
       _eraseReview = eraseReview,
       _current = _snapshot(
         authority,
         transferVerification,
         cleanup,
         remoteWork,
         eraseReview,
       ) {
    _subscriptions = [
      for (final changes in _inputChanges)
        changes.listen((_) => _publishIfChanged()),
    ];
  }

  /// The source of a client whose host publishes none of these facts yet.
  factory DeviceReplacementProjectionSource.unobserved() {
    const inputs = UnobservedDeviceReplacementInputs();
    return DeviceReplacementProjectionSource(
      authority: inputs,
      transferVerification: inputs,
      cleanup: inputs,
      remoteWork: inputs,
      eraseReview: inputs,
    );
  }

  final DeviceSubjectAuthorityInput _authority;
  final DeviceTransferVerificationInput _transferVerification;
  final DeviceCleanupSettlementInput _cleanup;
  final DeviceRemoteWorkControlInput _remoteWork;
  final DeviceEraseReviewInput _eraseReview;
  final StreamController<ProjectionUpdate<DeviceReplacementProjection>>
  _changes =
      StreamController<ProjectionUpdate<DeviceReplacementProjection>>.broadcast(
        sync: true,
      );
  late final List<StreamSubscription<void>> _subscriptions;
  DeviceReplacementProjection _current;
  bool _disposed = false;

  Iterable<Stream<void>> get _inputChanges => [
    _authority.changes,
    _transferVerification.changes,
    _cleanup.changes,
    _remoteWork.changes,
    _eraseReview.changes,
  ];

  @override
  DeviceReplacementProjection get current => _current;

  @override
  Stream<ProjectionUpdate<DeviceReplacementProjection>> get changes =>
      _changes.stream;

  void _publishIfChanged() {
    if (_disposed) return;
    final next = _snapshot(
      _authority,
      _transferVerification,
      _cleanup,
      _remoteWork,
      _eraseReview,
    );
    if (next == _current) return;
    _current = next;
    _changes.add(ProjectionUpdate(next));
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final subscription in _subscriptions.reversed) {
      await subscription.cancel();
    }
    await closeBroadcastController(_changes);
  }

  static DeviceReplacementProjection _snapshot(
    DeviceSubjectAuthorityInput authority,
    DeviceTransferVerificationInput transferVerification,
    DeviceCleanupSettlementInput cleanup,
    DeviceRemoteWorkControlInput remoteWork,
    DeviceEraseReviewInput eraseReview,
  ) => DeviceReplacementProjection(
    authority: authority.authority,
    identityRevocation: authority.identityRevocation,
    transferVerification: transferVerification.verification,
    pendingCleanup: cleanup.settlement,
    remoteWork: remoteWork.work,
    eraseReview: eraseReview.review,
  );
}

/// The inputs of a client that observes none of these facts yet.
///
/// The native owners for device transfer and replacement authority are not
/// implemented in this tree, and the ones that do exist have no Dart bridge, so
/// every fact is reported as unobserved instead of invented: an unknown
/// activation is not an active one, an unknown transfer is not a committed one,
/// a cleanup that was never requested is not a finished one, and an effect
/// nobody observed stays unknown.
final class UnobservedDeviceReplacementInputs
    implements
        DeviceSubjectAuthorityInput,
        DeviceTransferVerificationInput,
        DeviceCleanupSettlementInput,
        DeviceRemoteWorkControlInput,
        DeviceEraseReviewInput {
  const UnobservedDeviceReplacementInputs();

  @override
  Stream<void> get changes => const Stream<void>.empty();

  @override
  DeviceEndpointAuthorityFacts get authority =>
      const DeviceEndpointAuthorityFacts(
        endpointId: '',
        deviceLabel: '',
        activation: DeviceEndpointActivation.unknown,
        reachable: false,
        identityRotationEpoch: 0,
        authorizedRotationEpoch: 0,
        outboundAuthority: DeviceOutboundAuthoritySource.unknown,
      );

  @override
  DeviceIdentityRevocationFacts get identityRevocation =>
      const DeviceIdentityRevocationFacts(
        endpointId: '',
        revoked: false,
        absorbing: false,
      );

  @override
  DeviceTransferVerificationFacts get verification =>
      const DeviceTransferVerificationFacts(
        transferId: '',
        fileLabel: '',
        stage: DeviceTransferVerificationStage.unknown,
      );

  @override
  DevicePendingCleanupFacts get settlement => DevicePendingCleanupFacts(
    stage: DeviceCleanupStage.notAdmitted,
    outcome: DeviceCleanupOutcome.notRequested,
    receiptKind: DeviceCleanupReceiptKind.none,
  );

  @override
  DeviceRemoteWorkFacts get work => DeviceRemoteWorkFacts(
    workId: '',
    workLabel: '',
    selected: false,
    stopOwnership: DeviceStopOwnership.unknown,
  );

  @override
  DeviceEraseReviewFacts get review => DeviceEraseReviewFacts(
    targetEndpointId: '',
    targetDeviceLabel: '',
    affectedDataCategoryLabels: const [],
    consequenceStatement: '',
    postReconnectStatement: '',
    reviewPresented: false,
    confirmed: false,
    nativeAuthenticationPresent: false,
    ordinarySignInPresent: false,
  );
}
