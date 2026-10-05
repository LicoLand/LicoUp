import 'dart:async';

import 'package:licoup/src/application/features/mobile_relay/policy/device_replacement_policy.dart';
import 'package:licoup/src/composition/features/mobile_relay/device_entry_join.dart';
import 'package:licoup/src/presentation/mobile_relay/device_replacement_projection.dart';
import 'package:licoup/src/projections/mobile_relay/device_replacement_projection_source.dart';

import '../mobile_relay_binding_fixture.dart';

/// The old endpoint a replacement or an app-only wipe targets.
const String syntheticOldEndpointId = 'endpoint-old';

/// The endpoint taking the old one's role over.
const String syntheticNewEndpointId = 'endpoint-new';

/// The directory label the synthetic authority publishes for an active
/// endpoint.
const String syntheticActiveDirectoryState = 'active';

/// One synthetic authority fact.
///
/// The native owners that publish these facts are not implemented in this tree,
/// and the ones that exist have no Dart bridge, so every value here is
/// synthesized at the composition boundary rather than read from a native
/// command.
DeviceEndpointAuthorityFacts syntheticAuthorityFacts({
  String endpointId = syntheticOldEndpointId,
  String deviceLabel = 'Old laptop',
  DeviceEndpointActivation activation = DeviceEndpointActivation.active,
  bool reachable = true,
  int identityRotationEpoch = 7,
  int? authorizedRotationEpoch,
  DeviceOutboundAuthoritySource outboundAuthority =
      DeviceOutboundAuthoritySource.package,
  String directoryStateLabel = syntheticActiveDirectoryState,
  String authorizationValidUntilLabel = '2030-01-01T00:00:00Z',
}) => DeviceEndpointAuthorityFacts(
  endpointId: endpointId,
  deviceLabel: deviceLabel,
  activation: activation,
  reachable: reachable,
  identityRotationEpoch: identityRotationEpoch,
  authorizedRotationEpoch: authorizedRotationEpoch ?? identityRotationEpoch,
  outboundAuthority: outboundAuthority,
  directoryStateLabel: directoryStateLabel,
  authorizationValidUntilLabel: authorizationValidUntilLabel,
);

/// One synthetic revocation fact. Absorbing whenever it is revoked.
DeviceIdentityRevocationFacts syntheticRevocationFacts({
  String endpointId = syntheticOldEndpointId,
  bool revoked = false,
  String revokedAtLabel = '',
  String reasonCode = '',
}) => DeviceIdentityRevocationFacts(
  endpointId: endpointId,
  revoked: revoked,
  absorbing: revoked,
  revokedAtLabel: revokedAtLabel,
  reasonCode: reasonCode,
);

/// One synthetic transfer-verification fact.
DeviceTransferVerificationFacts syntheticTransferFacts({
  String transferId = 'transfer-1',
  String fileLabel = 'notes.txt',
  DeviceTransferVerificationStage stage =
      DeviceTransferVerificationStage.committed,
  int verifiedUnitCount = 2,
  int committedUnitCount = 2,
  String committedAtLabel = '2030-01-01T00:00:01Z',
}) => DeviceTransferVerificationFacts(
  transferId: transferId,
  fileLabel: fileLabel,
  stage: stage,
  verifiedUnitCount: verifiedUnitCount,
  committedUnitCount: committedUnitCount,
  committedAtLabel: committedAtLabel,
);

/// One synthetic cleanup fact.
DevicePendingCleanupFacts syntheticCleanupFacts({
  DeviceCleanupStage stage = DeviceCleanupStage.notAdmitted,
  DeviceCleanupOutcome outcome = DeviceCleanupOutcome.notRequested,
  DeviceCleanupReceiptKind receiptKind = DeviceCleanupReceiptKind.none,
  List<String> pendingEntryLabels = const [],
  int pendingEntryCount = 0,
  bool receiptIssued = false,
  bool receiptDelivered = false,
  bool replacementEndpointConfirmed = false,
  String receiptDeliveryFailureCode = '',
}) => DevicePendingCleanupFacts(
  stage: stage,
  outcome: outcome,
  receiptKind: receiptKind,
  pendingEntryLabels: pendingEntryLabels,
  pendingEntryCount: pendingEntryCount,
  receiptIssued: receiptIssued,
  receiptDelivered: receiptDelivered,
  replacementEndpointConfirmed: replacementEndpointConfirmed,
  receiptDeliveryFailureCode: receiptDeliveryFailureCode,
);

/// One synthetic remote effect.
DeviceRemoteEffectFacts syntheticRemoteEffect({
  String effectId = 'effect-1',
  String label = 'Stop the selected work',
  DeviceRemoteEffectState state = DeviceRemoteEffectState.confirmed,
  String requestedAtLabel = '2030-01-01T00:00:00Z',
  String observedAtLabel = '2030-01-01T00:00:02Z',
  bool lateResult = false,
}) => DeviceRemoteEffectFacts(
  effectId: effectId,
  label: label,
  state: state,
  requestedAtLabel: requestedAtLabel,
  observedAtLabel: observedAtLabel,
  lateResult: lateResult,
);

/// One synthetic remote work fact.
DeviceRemoteWorkFacts syntheticRemoteWork({
  String workId = 'work-1',
  String workLabel = 'Release the next milestone',
  bool selected = true,
  DeviceStopOwnership stopOwnership = DeviceStopOwnership.localOwner,
  bool stopAlreadyRequested = false,
  List<DeviceRemoteEffectFacts> effects = const [],
}) => DeviceRemoteWorkFacts(
  workId: workId,
  workLabel: workLabel,
  selected: selected,
  stopOwnership: stopOwnership,
  stopAlreadyRequested: stopAlreadyRequested,
  effects: effects,
);

/// One synthetic app-only erase review.
///
/// The defaults describe a review that is complete enough to confirm; every
/// rule this review guards is falsified by clearing exactly one of its fields.
DeviceEraseReviewFacts syntheticEraseReview({
  String targetEndpointId = syntheticOldEndpointId,
  String targetDeviceLabel = 'Old laptop',
  List<String> affectedDataCategoryLabels = const [
    'Conversations and history',
    'Local app state',
  ],
  String consequenceStatement = deviceAppOnlyEraseConsequenceStatement,
  String postReconnectStatement = deviceAppOnlyErasePostReconnectStatement,
  bool reviewPresented = true,
  bool confirmed = true,
  bool nativeAuthenticationPresent = true,
  bool ordinarySignInPresent = true,
  bool requiresExplicitConfirmation = true,
  bool requiresNativeAuthentication = true,
  bool executesAfterReconnect = true,
  int scopeEntryCount = 4,
}) => DeviceEraseReviewFacts(
  targetEndpointId: targetEndpointId,
  targetDeviceLabel: targetDeviceLabel,
  affectedDataCategoryLabels: affectedDataCategoryLabels,
  consequenceStatement: consequenceStatement,
  postReconnectStatement: postReconnectStatement,
  reviewPresented: reviewPresented,
  confirmed: confirmed,
  nativeAuthenticationPresent: nativeAuthenticationPresent,
  ordinarySignInPresent: ordinarySignInPresent,
  requiresExplicitConfirmation: requiresExplicitConfirmation,
  requiresNativeAuthentication: requiresNativeAuthentication,
  executesAfterReconnect: executesAfterReconnect,
  scopeEntryCount: scopeEntryCount,
);

/// One synthetic device projection with every group defaulted.
DeviceReplacementProjection syntheticDeviceReplacementProjection({
  DeviceEndpointAuthorityFacts? authority,
  DeviceIdentityRevocationFacts? identityRevocation,
  DeviceTransferVerificationFacts? transferVerification,
  DevicePendingCleanupFacts? pendingCleanup,
  DeviceRemoteWorkFacts? remoteWork,
  DeviceEraseReviewFacts? eraseReview,
}) => DeviceReplacementProjection(
  authority: authority ?? syntheticAuthorityFacts(),
  identityRevocation: identityRevocation ?? syntheticRevocationFacts(),
  transferVerification: transferVerification ?? syntheticTransferFacts(),
  pendingCleanup: pendingCleanup ?? syntheticCleanupFacts(),
  remoteWork: remoteWork ?? syntheticRemoteWork(),
  eraseReview: eraseReview ?? syntheticEraseReview(),
);

/// A replacement the current authority covers: the installed package owns the
/// outbound path and the authorization was issued for the epoch presented now.
DeviceReplacementProjection authorizedReplacementScenario() =>
    syntheticDeviceReplacementProjection();

/// The old endpoint rotated its identity after the authorization was issued, so
/// the recorded authorization covers an earlier epoch.
DeviceReplacementProjection freshIdentityScenario() =>
    syntheticDeviceReplacementProjection(
      authority: syntheticAuthorityFacts(
        identityRotationEpoch: 9,
        authorizedRotationEpoch: 7,
      ),
    );

/// The stop request left this client and nothing observed what it did.
DeviceReplacementProjection incompleteEffectsScenario() =>
    syntheticDeviceReplacementProjection(
      remoteWork: syntheticRemoteWork(
        effects: [
          syntheticRemoteEffect(
            state: DeviceRemoteEffectState.unknown,
            observedAtLabel: '',
          ),
        ],
      ),
    );

/// Every verified unit reached its destination.
DeviceReplacementProjection fullTransferScenario() =>
    syntheticDeviceReplacementProjection();

/// The units verified but no destination commit was observed.
DeviceReplacementProjection partialTransferScenario() =>
    syntheticDeviceReplacementProjection(
      transferVerification: syntheticTransferFacts(
        stage: DeviceTransferVerificationStage.verified,
        committedUnitCount: 0,
        committedAtLabel: '',
      ),
    );

/// The transfer failed after its units verified.
DeviceReplacementProjection sourceOnFailureScenario() =>
    syntheticDeviceReplacementProjection(
      transferVerification: syntheticTransferFacts(
        stage: DeviceTransferVerificationStage.failed,
        committedUnitCount: 0,
      ),
    );

/// The old endpoint stopped answering, and the last result arrived late.
DeviceReplacementProjection reconnectReplayScenario() =>
    syntheticDeviceReplacementProjection(
      authority: syntheticAuthorityFacts(
        activation: DeviceEndpointActivation.unknown,
        reachable: false,
      ),
      remoteWork: syntheticRemoteWork(
        effects: [
          syntheticRemoteEffect(
            state: DeviceRemoteEffectState.confirmed,
            lateResult: true,
          ),
        ],
      ),
    );

/// The narrowly authorized app-only cleanup: the file stage settled and the
/// receipt is partial by construction.
DeviceReplacementProjection restrictedCleanupScenario() =>
    syntheticDeviceReplacementProjection(
      pendingCleanup: syntheticCleanupFacts(
        stage: DeviceCleanupStage.filesSettled,
        outcome: DeviceCleanupOutcome.partial,
        receiptKind: DeviceCleanupReceiptKind.fileStage,
        pendingEntryLabels: const ['credentials', 'terminal-settlement'],
        pendingEntryCount: 2,
        receiptIssued: true,
        receiptDelivered: true,
      ),
    );

/// Every authorized stage settled, the final receipt was delivered and the
/// replacement endpoint confirmed it.
DeviceReplacementProjection allStageSettlementScenario() =>
    syntheticDeviceReplacementProjection(
      pendingCleanup: syntheticCleanupFacts(
        stage: DeviceCleanupStage.complete,
        outcome: DeviceCleanupOutcome.confirmedComplete,
        receiptKind: DeviceCleanupReceiptKind.finalCleanup,
        receiptIssued: true,
        receiptDelivered: true,
        replacementEndpointConfirmed: true,
      ),
    );

/// Every authorized stage settled locally, and the receipt never arrived.
DeviceReplacementProjection lostReceiptScenario() =>
    syntheticDeviceReplacementProjection(
      pendingCleanup: syntheticCleanupFacts(
        stage: DeviceCleanupStage.complete,
        outcome: DeviceCleanupOutcome.confirmedComplete,
        receiptKind: DeviceCleanupReceiptKind.finalCleanup,
        receiptIssued: true,
        receiptDelivered: false,
        replacementEndpointConfirmed: false,
        receiptDeliveryFailureCode: 'cleanup_receipt_path_unavailable',
      ),
    );

/// A revoked identity whose cleanup settled locally without a delivered
/// receipt.
DeviceReplacementProjection revokedWithLostReceiptScenario() =>
    syntheticDeviceReplacementProjection(
      identityRevocation: syntheticRevocationFacts(
        revoked: true,
        revokedAtLabel: '2030-01-01T00:00:03Z',
        reasonCode: 'endpoint_replacement_authorized',
      ),
      pendingCleanup: syntheticCleanupFacts(
        stage: DeviceCleanupStage.complete,
        outcome: DeviceCleanupOutcome.confirmedComplete,
        receiptKind: DeviceCleanupReceiptKind.finalCleanup,
        receiptIssued: true,
      ),
    );

/// A synthetic device replacement input set.
///
/// It is a port, not a native owner: the facts the native owners would publish
/// are supplied here so a scenario can be driven without a native command.
final class SyntheticDeviceReplacementInputs
    implements
        DeviceSubjectAuthorityInput,
        DeviceTransferVerificationInput,
        DeviceCleanupSettlementInput,
        DeviceRemoteWorkControlInput,
        DeviceEraseReviewInput {
  SyntheticDeviceReplacementInputs(DeviceReplacementProjection projection)
    : _projection = projection;

  final StreamController<void> _changes = StreamController<void>.broadcast(
    sync: true,
  );
  DeviceReplacementProjection _projection;

  @override
  Stream<void> get changes => _changes.stream;

  @override
  DeviceEndpointAuthorityFacts get authority => _projection.authority;

  @override
  DeviceIdentityRevocationFacts get identityRevocation =>
      _projection.identityRevocation;

  @override
  DeviceTransferVerificationFacts get verification =>
      _projection.transferVerification;

  @override
  DevicePendingCleanupFacts get settlement => _projection.pendingCleanup;

  @override
  DeviceRemoteWorkFacts get work => _projection.remoteWork;

  @override
  DeviceEraseReviewFacts get review => _projection.eraseReview;

  void publish(DeviceReplacementProjection projection) {
    _projection = projection;
    _changes.add(null);
  }

  Future<void> dispose() => _changes.close();
}

/// A synthetic resolution of the optional endpoint collaboration package.
final class SyntheticEndpointCollaborationAvailability
    implements EndpointCollaborationAvailabilityPort {
  SyntheticEndpointCollaborationAvailability(this._availability);

  EndpointCollaborationAvailability _availability;

  @override
  EndpointCollaborationAvailability get availability => _availability;

  void resolve(EndpointCollaborationAvailability value) {
    _availability = value;
  }
}

/// A synthetic device replacement and control entry.
///
/// The native entry this stands for is not implemented in this tree, so the
/// composition boundary supplies the admission here and records every action it
/// was asked about.
final class SyntheticDeviceReplacementControl
    implements DeviceReplacementControlPort {
  SyntheticDeviceReplacementControl({
    Set<DeviceReplacementAction> admitted = const {
      DeviceReplacementAction.reviewErase,
      DeviceReplacementAction.submitEraseConfirmation,
      DeviceReplacementAction.requestRemoteStop,
      DeviceReplacementAction.refreshRemoteWorkState,
      DeviceReplacementAction.refreshTransferVerification,
      DeviceReplacementAction.reviewPendingCleanup,
      DeviceReplacementAction.reconnectEndpoint,
    },
    this.refusal = DeviceReplacementControlRefusal.endpointNotAuthorized,
  }) : _admitted = admitted;

  final Set<DeviceReplacementAction> _admitted;
  final DeviceReplacementControlRefusal refusal;
  final List<DeviceReplacementAction> asked = <DeviceReplacementAction>[];

  @override
  DeviceReplacementControlAdmission admit(DeviceReplacementAction action) {
    asked.add(action);
    return _admitted.contains(action)
        ? const DeviceReplacementControlAdmission.admitted()
        : DeviceReplacementControlAdmission.refused(refusal);
  }
}

/// One synthetic two-endpoint composition: the old endpoint's device facts, the
/// optional package's resolution, the replacement/control entry and the mounted
/// relay feature's own binding.
final class SyntheticDeviceEntryComposition {
  SyntheticDeviceEntryComposition({
    required DeviceReplacementProjection projection,
    EndpointCollaborationAvailability availability =
        const EndpointCollaborationAvailability.active('0.3.0'),
    SyntheticDeviceReplacementControl? control,
  }) : deviceInputs = SyntheticDeviceReplacementInputs(projection),
       package = SyntheticEndpointCollaborationAvailability(availability),
       control = control ?? SyntheticDeviceReplacementControl() {
    relayFixture = MobileRelayBindingFixture();
    deviceState = DeviceReplacementProjectionSource(
      authority: deviceInputs,
      transferVerification: deviceInputs,
      cleanup: deviceInputs,
      remoteWork: deviceInputs,
      eraseReview: deviceInputs,
    );
    join = DeviceEntryJoin(
      package: package,
      control: this.control,
      relay: relayFixture.binding,
      deviceState: deviceState,
    );
  }

  final SyntheticDeviceReplacementInputs deviceInputs;
  final SyntheticEndpointCollaborationAvailability package;
  final SyntheticDeviceReplacementControl control;
  late final MobileRelayBindingFixture relayFixture;
  late final DeviceReplacementProjectionSource deviceState;
  late final DeviceEntryJoin join;

  void publish(DeviceReplacementProjection projection) =>
      deviceInputs.publish(projection);

  Future<void> dispose() async {
    await join.dispose();
    await relayFixture.dispose();
    await deviceInputs.dispose();
  }
}
