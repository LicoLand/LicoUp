import 'package:licoup/src/presentation/presentation_semantics.dart';

/// The consequence an app-only erase review has to name verbatim before it can
/// be confirmed.
///
/// The app-only cleanup this client can offer removes this application's own
/// data. It is not a device erase and it is not the native custody cleanup
/// `crates/licoup-native/src/domain/mobile_relay/secret_custody/cleanup_authority.rs`
/// authorizes, so it names its own consequence instead of borrowing
/// `irreversibleLocalSecretErasure`.
const String deviceAppOnlyEraseConsequenceStatement =
    'Irreversibly removes this application\'s local data on the named device. '
    'The device itself is not erased or reset.';

/// The lifecycle a confirmed app-only wipe follows, named for the operator
/// before they confirm it.
///
/// The old endpoint is not present while the review is confirmed and is not
/// asked again: the wipe executes once that endpoint reconnects. The statement
/// is part of the review rather than a footnote, because the operator is
/// consenting to an effect that happens later, on a device that is not
/// reachable now.
const String deviceAppOnlyErasePostReconnectStatement =
    'A confirmed app-only wipe executes after the old endpoint reconnects. '
    'No further manual confirmation is required on the old side.';

/// What the host's endpoint authority says about one endpoint's activation.
///
/// Activation is its own fact and is never derived from reachability: an
/// endpoint that does not answer is [unknown], which is a different answer from
/// an inactive or revoked identity.
enum DeviceEndpointActivation { unknown, inactive, active, revoked }

/// Which implementation currently owns this client's outbound endpoint path.
///
/// Mirrors the two answers `crates/licoup-native`'s endpoint collaboration gate
/// publishes: an installed package owns the path, or this build runs the
/// kernel's own pre-package path. The pre-package path is a statement about
/// which implementation is running, never a grant.
enum DeviceOutboundAuthoritySource { unknown, package, legacyInKernel, refused }

/// Fact group 1: endpoint authority and activation.
///
/// The fields are what the authority owners publish about one endpoint. Nothing
/// here is inferred from a transfer, a cleanup or a user-interface badge.
final class DeviceEndpointAuthorityFacts {
  const DeviceEndpointAuthorityFacts({
    required this.endpointId,
    required this.deviceLabel,
    required this.activation,
    required this.reachable,
    required this.identityRotationEpoch,
    required this.authorizedRotationEpoch,
    required this.outboundAuthority,
    this.directoryStateLabel = '',
    this.authorizationValidUntilLabel = '',
  });

  final String endpointId;
  final String deviceLabel;

  /// The activation the directory reports, or [DeviceEndpointActivation.unknown]
  /// when no answer was carried.
  final DeviceEndpointActivation activation;

  /// Whether this endpoint answered at all. An unreachable endpoint's
  /// activation stays whatever the last answer was, and [activation] is
  /// [DeviceEndpointActivation.unknown] when there was none.
  final bool reachable;

  /// The identity rotation epoch this endpoint currently presents. A later
  /// epoch is a different identity.
  final int identityRotationEpoch;

  /// The identity rotation epoch the authorization this client holds was issued
  /// for. When it differs from [identityRotationEpoch] the recorded
  /// authorization covers an earlier identity and does not authorize the one
  /// presented now.
  final int authorizedRotationEpoch;

  final DeviceOutboundAuthoritySource outboundAuthority;
  final String directoryStateLabel;
  final String authorizationValidUntilLabel;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DeviceEndpointAuthorityFacts &&
          other.endpointId == endpointId &&
          other.deviceLabel == deviceLabel &&
          other.activation == activation &&
          other.reachable == reachable &&
          other.identityRotationEpoch == identityRotationEpoch &&
          other.authorizedRotationEpoch == authorizedRotationEpoch &&
          other.outboundAuthority == outboundAuthority &&
          other.directoryStateLabel == directoryStateLabel &&
          other.authorizationValidUntilLabel == authorizationValidUntilLabel;

  @override
  int get hashCode => Object.hash(
    endpointId,
    deviceLabel,
    activation,
    reachable,
    identityRotationEpoch,
    authorizedRotationEpoch,
    outboundAuthority,
    directoryStateLabel,
    authorizationValidUntilLabel,
  );
}

/// Fact group 2: identity revocation.
///
/// Revocation is recorded separately from activation because the two are
/// decided by different owners and because revocation is absorbing: a revoked
/// identity is not re-admitted by a later badge, a later transfer or a lost
/// receipt.
final class DeviceIdentityRevocationFacts {
  const DeviceIdentityRevocationFacts({
    required this.endpointId,
    required this.revoked,
    required this.absorbing,
    this.revokedAtLabel = '',
    this.reasonCode = '',
  });

  final String endpointId;
  final bool revoked;

  /// Whether this revocation is absorbing, as the endpoint-side contract
  /// requires. Truthfully `true` whenever [revoked] is true; a revocation a
  /// later event could undo is reported here rather than assumed.
  final bool absorbing;

  final String revokedAtLabel;
  final String reasonCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DeviceIdentityRevocationFacts &&
          other.endpointId == endpointId &&
          other.revoked == revoked &&
          other.absorbing == absorbing &&
          other.revokedAtLabel == revokedAtLabel &&
          other.reasonCode == reasonCode;

  @override
  int get hashCode =>
      Object.hash(endpointId, revoked, absorbing, revokedAtLabel, reasonCode);
}

/// How far one transfer's verified commit has progressed.
enum DeviceTransferVerificationStage {
  /// No answer was carried.
  unknown,

  /// The unit verified but no destination commit was observed.
  verified,

  /// The destination commit was observed.
  committed,

  /// The transfer failed after verification.
  failed,
}

/// Fact group 3: transfer verification.
final class DeviceTransferVerificationFacts {
  const DeviceTransferVerificationFacts({
    required this.transferId,
    required this.fileLabel,
    required this.stage,
    this.verifiedUnitCount = 0,
    this.committedUnitCount = 0,
    this.committedAtLabel = '',
  });

  final String transferId;
  final String fileLabel;
  final DeviceTransferVerificationStage stage;
  final int verifiedUnitCount;
  final int committedUnitCount;
  final String committedAtLabel;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DeviceTransferVerificationFacts &&
          other.transferId == transferId &&
          other.fileLabel == fileLabel &&
          other.stage == stage &&
          other.verifiedUnitCount == verifiedUnitCount &&
          other.committedUnitCount == committedUnitCount &&
          other.committedAtLabel == committedAtLabel;

  @override
  int get hashCode => Object.hash(
    transferId,
    fileLabel,
    stage,
    verifiedUnitCount,
    committedUnitCount,
    committedAtLabel,
  );
}

/// How far a local cleanup progressed.
///
/// The order is the cleanup's own and mirrors the journal in
/// `components/endpoint-collaboration/cleanup/src/cleanup/journal.rs`: no stage
/// is skipped and a file stage stops at [filesSettled].
enum DeviceCleanupStage {
  notAdmitted,
  admitted,
  writersQuiesced,
  filesSettled,
  credentialsSettled,
  terminalSettlement,
  complete,
}

/// Which report a cleanup issued to the replacement endpoint.
///
/// Mirrors `CleanupReceiptKind`. A [fileStage] receipt can never report
/// completion, so it is never converted into [finalCleanup] by this vocabulary.
enum DeviceCleanupReceiptKind { none, fileStage, finalCleanup }

/// The truthful state of a local cleanup.
///
/// [offline], [platformDenied] and [partial] are separate answers from
/// [confirmedComplete] because they are separate observations: an unreachable
/// endpoint, a platform that refused a removal, and a cleanup that finished with
/// entries still pending. None of them is completion.
enum DeviceCleanupOutcome {
  notRequested,
  offline,
  platformDenied,
  partial,
  confirmedComplete,
}

/// Fact group 4: pending cleanup.
///
/// The local settlement, the issued receipt and the replacement endpoint's own
/// confirmation are three separate fields, because they are three separate
/// observations made by three different owners.
final class DevicePendingCleanupFacts {
  DevicePendingCleanupFacts({
    required this.stage,
    required this.outcome,
    required this.receiptKind,
    Iterable<String> pendingEntryLabels = const [],
    this.pendingEntryCount = 0,
    this.receiptIssued = false,
    this.receiptDelivered = false,
    this.replacementEndpointConfirmed = false,
    this.receiptDeliveryFailureCode = '',
  }) : pendingEntryLabels = immutablePresentationList(pendingEntryLabels);

  final DeviceCleanupStage stage;
  final DeviceCleanupOutcome outcome;
  final DeviceCleanupReceiptKind receiptKind;
  final List<String> pendingEntryLabels;
  final int pendingEntryCount;

  /// Whether a receipt was issued for delivery on the restricted control path.
  final bool receiptIssued;

  /// Whether that receipt reached the restricted path. A completed local
  /// settlement stays unconfirmed while this is false.
  final bool receiptDelivered;

  /// Whether the replacement endpoint itself confirmed the receipt. Only the
  /// replacement endpoint can observe arrival, so a lost receipt stays
  /// unconfirmed here rather than being read as success.
  final bool replacementEndpointConfirmed;

  final String receiptDeliveryFailureCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DevicePendingCleanupFacts &&
          other.stage == stage &&
          other.outcome == outcome &&
          other.receiptKind == receiptKind &&
          samePresentationList(other.pendingEntryLabels, pendingEntryLabels) &&
          other.pendingEntryCount == pendingEntryCount &&
          other.receiptIssued == receiptIssued &&
          other.receiptDelivered == receiptDelivered &&
          other.replacementEndpointConfirmed == replacementEndpointConfirmed &&
          other.receiptDeliveryFailureCode == receiptDeliveryFailureCode;

  @override
  int get hashCode => Object.hash(
    stage,
    outcome,
    receiptKind,
    Object.hashAll(pendingEntryLabels),
    pendingEntryCount,
    receiptIssued,
    receiptDelivered,
    replacementEndpointConfirmed,
    receiptDeliveryFailureCode,
  );
}

/// What is known about one remote effect this client requested.
///
/// [unknown] is a first-class answer: the request left this client and no owner
/// observed what it did. It is never collapsed into [confirmed] or [refused].
enum DeviceRemoteEffectState {
  unknown,
  pending,
  confirmed,
  refused,
  superseded,
}

/// Fact group 5a: one remote effect.
final class DeviceRemoteEffectFacts {
  const DeviceRemoteEffectFacts({
    required this.effectId,
    required this.label,
    required this.state,
    this.requestedAtLabel = '',
    this.observedAtLabel = '',
    this.lateResult = false,
  });

  final String effectId;
  final String label;
  final DeviceRemoteEffectState state;
  final String requestedAtLabel;
  final String observedAtLabel;

  /// Whether this result arrived after the request's own settlement window, so
  /// it describes an older attempt rather than the current one.
  final bool lateResult;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DeviceRemoteEffectFacts &&
          other.effectId == effectId &&
          other.label == label &&
          other.state == state &&
          other.requestedAtLabel == requestedAtLabel &&
          other.observedAtLabel == observedAtLabel &&
          other.lateResult == lateResult;

  @override
  int get hashCode => Object.hash(
    effectId,
    label,
    state,
    requestedAtLabel,
    observedAtLabel,
    lateResult,
  );
}

/// Who currently owns stopping one piece of work.
enum DeviceStopOwnership { unknown, localOwner, remoteRequester, noOwner }

/// Fact group 5b: remote work and control state.
final class DeviceRemoteWorkFacts {
  DeviceRemoteWorkFacts({
    required this.workId,
    required this.workLabel,
    required this.selected,
    required this.stopOwnership,
    Iterable<DeviceRemoteEffectFacts> effects = const [],
    this.stopAlreadyRequested = false,
  }) : effects = immutablePresentationList(effects);

  final String workId;
  final String workLabel;
  final bool selected;
  final DeviceStopOwnership stopOwnership;
  final bool stopAlreadyRequested;
  final List<DeviceRemoteEffectFacts> effects;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DeviceRemoteWorkFacts &&
          other.workId == workId &&
          other.workLabel == workLabel &&
          other.selected == selected &&
          other.stopOwnership == stopOwnership &&
          other.stopAlreadyRequested == stopAlreadyRequested &&
          samePresentationList(other.effects, effects);

  @override
  int get hashCode => Object.hash(
    workId,
    workLabel,
    selected,
    stopOwnership,
    stopAlreadyRequested,
    Object.hashAll(effects),
  );
}

/// Fact group 6: the app-only erase review.
///
/// Every field an informed confirmation needs is a named fact on this value, so
/// a confirmation that is missing one is refusable rather than assumable.
final class DeviceEraseReviewFacts {
  DeviceEraseReviewFacts({
    required this.targetEndpointId,
    required this.targetDeviceLabel,
    required Iterable<String> affectedDataCategoryLabels,
    required this.consequenceStatement,
    required this.postReconnectStatement,
    required this.reviewPresented,
    required this.confirmed,
    required this.nativeAuthenticationPresent,
    required this.ordinarySignInPresent,
    this.requiresExplicitConfirmation = true,
    this.requiresNativeAuthentication = true,
    this.executesAfterReconnect = true,
    this.scopeEntryCount = 0,
  }) : affectedDataCategoryLabels = immutablePresentationList(
         affectedDataCategoryLabels,
       );

  final String targetEndpointId;
  final String targetDeviceLabel;

  /// The data categories the wipe would remove on the named device.
  final List<String> affectedDataCategoryLabels;

  /// The destructive consequence the operator has to have been shown.
  final String consequenceStatement;

  /// When and how the wipe executes, named for the operator.
  final String postReconnectStatement;

  /// Whether the review was put in front of the operator at all.
  final bool reviewPresented;

  /// Whether the operator explicitly confirmed this review.
  final bool confirmed;

  /// Whether the platform's own authentication is present for this operation.
  final bool nativeAuthenticationPresent;

  /// Whether the operator merely holds an ordinary signed-in session. It is
  /// recorded so that no caller can mistake it for authentication; it never
  /// stands in for [nativeAuthenticationPresent].
  final bool ordinarySignInPresent;

  final bool requiresExplicitConfirmation;
  final bool requiresNativeAuthentication;
  final bool executesAfterReconnect;

  /// How many bounded scope entries the review names, when the inventory is
  /// known. Zero means the inventory has not been enumerated.
  final int scopeEntryCount;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DeviceEraseReviewFacts &&
          other.targetEndpointId == targetEndpointId &&
          other.targetDeviceLabel == targetDeviceLabel &&
          samePresentationList(
            other.affectedDataCategoryLabels,
            affectedDataCategoryLabels,
          ) &&
          other.consequenceStatement == consequenceStatement &&
          other.postReconnectStatement == postReconnectStatement &&
          other.reviewPresented == reviewPresented &&
          other.confirmed == confirmed &&
          other.nativeAuthenticationPresent == nativeAuthenticationPresent &&
          other.ordinarySignInPresent == ordinarySignInPresent &&
          other.requiresExplicitConfirmation == requiresExplicitConfirmation &&
          other.requiresNativeAuthentication == requiresNativeAuthentication &&
          other.executesAfterReconnect == executesAfterReconnect &&
          other.scopeEntryCount == scopeEntryCount;

  @override
  int get hashCode => Object.hash(
    targetEndpointId,
    targetDeviceLabel,
    Object.hashAll(affectedDataCategoryLabels),
    consequenceStatement,
    postReconnectStatement,
    reviewPresented,
    confirmed,
    nativeAuthenticationPresent,
    ordinarySignInPresent,
    requiresExplicitConfirmation,
    requiresNativeAuthentication,
    executesAfterReconnect,
    scopeEntryCount,
  );
}

/// The distinct replacement, cleanup and remote-control facts one device
/// surface renders.
///
/// The six groups stay separate fields on purpose. A restart or reconnect
/// re-reads them independently: a reachable endpoint with a revoked identity, a
/// committed transfer with a pending cleanup, and a confirmed cleanup whose
/// receipt was never delivered are all representable here and none of them is
/// derived from another.
final class DeviceReplacementProjection {
  const DeviceReplacementProjection({
    required this.authority,
    required this.identityRevocation,
    required this.transferVerification,
    required this.pendingCleanup,
    required this.remoteWork,
    required this.eraseReview,
  });

  /// Group 1: endpoint authority and activation.
  final DeviceEndpointAuthorityFacts authority;

  /// Group 2: identity revocation.
  final DeviceIdentityRevocationFacts identityRevocation;

  /// Group 3: transfer verification.
  final DeviceTransferVerificationFacts transferVerification;

  /// Group 4: pending cleanup, its receipt and the replacement's confirmation.
  final DevicePendingCleanupFacts pendingCleanup;

  /// Group 5: remote work, its stop ownership and its effects.
  final DeviceRemoteWorkFacts remoteWork;

  /// Group 6: the app-only erase review.
  final DeviceEraseReviewFacts eraseReview;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DeviceReplacementProjection &&
          other.authority == authority &&
          other.identityRevocation == identityRevocation &&
          other.transferVerification == transferVerification &&
          other.pendingCleanup == pendingCleanup &&
          other.remoteWork == remoteWork &&
          other.eraseReview == eraseReview;

  @override
  int get hashCode => Object.hash(
    authority,
    identityRevocation,
    transferVerification,
    pendingCleanup,
    remoteWork,
    eraseReview,
  );
}
