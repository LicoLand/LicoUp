import 'package:licoup/src/presentation/mobile_relay/device_replacement_projection.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

/// One intent the device replacement and cleanup surface can offer.
///
/// The vocabulary deliberately carries no action that re-drives a remote
/// effect and none that returns key material: the control ledger refuses a
/// second ask for a request it has already answered, and this client never
/// exports custody keys to a replacement.
enum DeviceReplacementAction {
  /// Open the app-only erase review for the named target device.
  reviewErase,

  /// Submit the reviewed, explicitly confirmed app-only erase.
  submitEraseConfirmation,

  /// Ask the work's own owner to stop the selected work.
  requestRemoteStop,

  /// Re-read the remote work and effect facts this client already holds.
  refreshRemoteWorkState,

  /// Re-read the transfer verification facts.
  refreshTransferVerification,

  /// Re-read the pending cleanup, its receipt and the replacement's answer.
  reviewPendingCleanup,

  /// Try the unreachable endpoint again.
  reconnectEndpoint,
}

/// The truthful cleanup state that may be shown.
enum DeviceCleanupStatus {
  notRequested,
  offline,
  platformDenied,
  partial,
  confirmedComplete,
}

/// The cleanup state, together with the only badge it may carry.
///
/// The badge is a separate field from [status] because it is a separate
/// decision: a settled cleanup whose receipt never arrived is
/// [DeviceCleanupStatus.confirmedComplete] locally and still carries no erased
/// badge.
final class DeviceCleanupPresentation {
  DeviceCleanupPresentation({
    required this.status,
    Iterable<String> pendingEntryLabels = const [],
    required this.pendingEntryCount,
    required this.localSettlementComplete,
    required this.receiptIssued,
    required this.receiptDelivered,
    required this.replacementEndpointConfirmed,
    required this.erasedBadgeVisible,
    this.receiptDeliveryFailureCode = '',
  }) : pendingEntryLabels = immutablePresentationList(pendingEntryLabels);

  final DeviceCleanupStatus status;
  final List<String> pendingEntryLabels;
  final int pendingEntryCount;

  /// Every authorized stage settled locally, observed rather than assumed.
  final bool localSettlementComplete;

  final bool receiptIssued;

  /// Whether the restricted control path accepted the receipt.
  final bool receiptDelivered;

  /// Whether the replacement endpoint itself confirmed the receipt.
  final bool replacementEndpointConfirmed;

  /// Whether user-visible "erased" evidence may be shown at all.
  final bool erasedBadgeVisible;

  final String receiptDeliveryFailureCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DeviceCleanupPresentation &&
          other.status == status &&
          samePresentationList(other.pendingEntryLabels, pendingEntryLabels) &&
          other.pendingEntryCount == pendingEntryCount &&
          other.localSettlementComplete == localSettlementComplete &&
          other.receiptIssued == receiptIssued &&
          other.receiptDelivered == receiptDelivered &&
          other.replacementEndpointConfirmed == replacementEndpointConfirmed &&
          other.erasedBadgeVisible == erasedBadgeVisible &&
          other.receiptDeliveryFailureCode == receiptDeliveryFailureCode;

  @override
  int get hashCode => Object.hash(
    status,
    Object.hashAll(pendingEntryLabels),
    pendingEntryCount,
    localSettlementComplete,
    receiptIssued,
    receiptDelivered,
    replacementEndpointConfirmed,
    erasedBadgeVisible,
    receiptDeliveryFailureCode,
  );
}

/// How one remote effect may be presented.
final class DeviceRemoteEffectPresentation {
  const DeviceRemoteEffectPresentation({
    required this.effect,
    required this.carriesOrdinaryAuthority,
    required this.actionable,
    required this.offeredActions,
    this.reasonCode = '',
  });

  final DeviceRemoteEffectFacts effect;

  /// Whether this result still carries ordinary authority over the work.
  final bool carriesOrdinaryAuthority;

  /// Whether this surface may drive the effect again. Always false.
  final bool actionable;

  /// The only actions an effect may offer: re-reading held facts.
  final List<DeviceReplacementAction> offeredActions;

  /// Why this effect is not actionable, when a reason is known.
  final String reasonCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DeviceRemoteEffectPresentation &&
          other.effect == effect &&
          other.carriesOrdinaryAuthority == carriesOrdinaryAuthority &&
          other.actionable == actionable &&
          samePresentationList(other.offeredActions, offeredActions) &&
          other.reasonCode == reasonCode;

  @override
  int get hashCode => Object.hash(
    effect,
    carriesOrdinaryAuthority,
    actionable,
    Object.hashAll(offeredActions),
    reasonCode,
  );
}

/// A confirmation record that is complete enough to submit.
///
/// The policy only builds one when the review is explicit and the platform's
/// own authentication is present, so holding one of these means the gates below
/// passed. It carries the bounded review facts and no key material.
final class DeviceEraseConfirmation {
  DeviceEraseConfirmation({
    required this.targetEndpointId,
    required this.targetDeviceLabel,
    required Iterable<String> affectedDataCategoryLabels,
    required this.consequenceStatement,
    required this.postReconnectStatement,
    required this.executesAfterReconnect,
    required this.scopeEntryCount,
  }) : affectedDataCategoryLabels = immutablePresentationList(
         affectedDataCategoryLabels,
       );

  final String targetEndpointId;
  final String targetDeviceLabel;
  final List<String> affectedDataCategoryLabels;
  final String consequenceStatement;
  final String postReconnectStatement;
  final bool executesAfterReconnect;
  final int scopeEntryCount;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DeviceEraseConfirmation &&
          other.targetEndpointId == targetEndpointId &&
          other.targetDeviceLabel == targetDeviceLabel &&
          samePresentationList(
            other.affectedDataCategoryLabels,
            affectedDataCategoryLabels,
          ) &&
          other.consequenceStatement == consequenceStatement &&
          other.postReconnectStatement == postReconnectStatement &&
          other.executesAfterReconnect == executesAfterReconnect &&
          other.scopeEntryCount == scopeEntryCount;

  @override
  int get hashCode => Object.hash(
    targetEndpointId,
    targetDeviceLabel,
    Object.hashAll(affectedDataCategoryLabels),
    consequenceStatement,
    postReconnectStatement,
    executesAfterReconnect,
    scopeEntryCount,
  );
}

/// Pure decisions over the device replacement facts.
///
/// Every method is a function of the facts it is handed. Nothing here reaches a
/// controller, a store or a network, and nothing here turns one fact into
/// another: an offline endpoint never becomes an erased device, a settled local
/// cleanup never becomes a delivered receipt, and a late remote result never
/// becomes ordinary authority.
abstract final class DeviceReplacementPolicy {
  /// The review is not explicit enough to confirm.
  static const String eraseRefusalReviewNotExplicit =
      'device_erase_review_not_explicit';

  /// The operator has not confirmed the review.
  static const String eraseRefusalNotConfirmed = 'device_erase_not_confirmed';

  /// The platform's own authentication is absent. An ordinary signed-in
  /// session never stands in for it.
  static const String eraseRefusalNativeAuthenticationMissing =
      'device_erase_native_authentication_missing';

  /// The current endpoint authority does not permit an outbound effect.
  static const String eraseRefusalOutboundNotAuthorized =
      'device_erase_outbound_not_authorized';

  /// Why one remote effect is not actionable.
  static const String remoteEffectUnknown = 'device_remote_effect_unknown';

  /// Why a result observed late is not actionable.
  static const String remoteEffectLateResult =
      'device_remote_effect_late_result';

  /// Why an effect whose request was already answered is not actionable.
  static const String remoteEffectAlreadyAnswered =
      'device_remote_effect_already_answered';

  /// The actions the current facts authorize, in vocabulary order.
  ///
  /// An action appears here only when the facts that authorize it are present
  /// now: a cross-device effect additionally needs the installed package to own
  /// this client's outbound path, a stop needs this host to own the work's stop,
  /// and a submit needs a confirmation the gates below accepted.
  static List<DeviceReplacementAction> offeredActions(
    DeviceReplacementProjection projection,
  ) {
    final authority = projection.authority;
    final revocation = projection.identityRevocation;
    final review = projection.eraseReview;
    final work = projection.remoteWork;
    final cleanup = projection.pendingCleanup;
    final actions = <DeviceReplacementAction>[];

    // Reading facts this client already holds needs no authority, and it is what
    // a restart or reconnect re-reads.
    actions.add(DeviceReplacementAction.refreshRemoteWorkState);
    actions.add(DeviceReplacementAction.refreshTransferVerification);
    if (cleanup.outcome != DeviceCleanupOutcome.notRequested) {
      actions.add(DeviceReplacementAction.reviewPendingCleanup);
    }
    if (!authority.reachable) {
      actions.add(DeviceReplacementAction.reconnectEndpoint);
    }

    // Reviewing is not an effect, so it is offered while there is a named target
    // and nothing has been confirmed yet.
    if (review.targetEndpointId.isNotEmpty && !review.confirmed) {
      actions.add(DeviceReplacementAction.reviewErase);
    }

    final currentAuthority =
        authority.activation == DeviceEndpointActivation.active &&
        authority.outboundAuthority == DeviceOutboundAuthoritySource.package &&
        authority.identityRotationEpoch == authority.authorizedRotationEpoch &&
        !revocation.revoked;

    if (currentAuthority && eraseConfirmationRefusal(projection) == null) {
      actions.add(DeviceReplacementAction.submitEraseConfirmation);
    }

    // A stop is asked of the work's own owner, so this host must own that stop
    // and must not have asked already.
    if (currentAuthority &&
        work.selected &&
        work.stopOwnership == DeviceStopOwnership.localOwner &&
        !work.stopAlreadyRequested) {
      actions.add(DeviceReplacementAction.requestRemoteStop);
    }

    return immutablePresentationList(
      DeviceReplacementAction.values.where(actions.contains),
    );
  }

  /// The truthful cleanup state and the only badge it may carry.
  ///
  /// A [DeviceCleanupOutcome.confirmedComplete] claim is accepted only when the
  /// facts behind it hold: every stage settled, nothing pending, and a final
  /// cleanup receipt. A file-stage receipt is partial by construction, so it can
  /// never reach [DeviceCleanupStatus.confirmedComplete], and an offline or
  /// platform-denied cleanup states its own answer instead of a completion.
  static DeviceCleanupPresentation cleanupPresentation(
    DevicePendingCleanupFacts facts,
  ) {
    final settledAllStages =
        facts.stage == DeviceCleanupStage.complete &&
        facts.pendingEntryCount == 0;
    final finalReceipt =
        facts.receiptKind == DeviceCleanupReceiptKind.finalCleanup;
    final localSettlementComplete = settledAllStages && finalReceipt;
    final status = switch (facts.outcome) {
      DeviceCleanupOutcome.notRequested => DeviceCleanupStatus.notRequested,
      DeviceCleanupOutcome.offline => DeviceCleanupStatus.offline,
      DeviceCleanupOutcome.platformDenied => DeviceCleanupStatus.platformDenied,
      DeviceCleanupOutcome.partial => DeviceCleanupStatus.partial,
      DeviceCleanupOutcome.confirmedComplete =>
        localSettlementComplete
            ? DeviceCleanupStatus.confirmedComplete
            : DeviceCleanupStatus.partial,
    };
    // Local settlement, receipt delivery and the replacement's own confirmation
    // are three observations. Only the third one may show erased evidence.
    final erasedBadgeVisible =
        status == DeviceCleanupStatus.confirmedComplete &&
        facts.receiptIssued &&
        facts.receiptDelivered &&
        facts.replacementEndpointConfirmed;
    return DeviceCleanupPresentation(
      status: status,
      pendingEntryLabels: facts.pendingEntryLabels,
      pendingEntryCount: facts.pendingEntryCount,
      localSettlementComplete: localSettlementComplete,
      receiptIssued: facts.receiptIssued,
      receiptDelivered: facts.receiptDelivered,
      replacementEndpointConfirmed: facts.replacementEndpointConfirmed,
      erasedBadgeVisible: erasedBadgeVisible,
      receiptDeliveryFailureCode: facts.receiptDeliveryFailureCode,
    );
  }

  /// Whether this remote result still carries ordinary authority.
  ///
  /// An unobserved effect carries none, and a result that arrived late
  /// describes an older attempt, so it is reported as late rather than as the
  /// current outcome.
  static bool carriesOrdinaryAuthority(DeviceRemoteEffectFacts effect) =>
      effect.state != DeviceRemoteEffectState.unknown && !effect.lateResult;

  /// How one remote effect is presented, and what may be done with it.
  ///
  /// No effect is actionable: a request the ledger already answered is never
  /// asked again, an effect nobody observed has no request identity to re-ask,
  /// and a late result belongs to an older attempt. An unknown effect is
  /// therefore visible and offers only a re-read, never a replay.
  static DeviceRemoteEffectPresentation effectPresentation(
    DeviceRemoteEffectFacts effect,
  ) {
    final unknown = effect.state == DeviceRemoteEffectState.unknown;
    final reason = unknown
        ? remoteEffectUnknown
        : effect.lateResult
        ? remoteEffectLateResult
        : remoteEffectAlreadyAnswered;
    return DeviceRemoteEffectPresentation(
      effect: effect,
      carriesOrdinaryAuthority: carriesOrdinaryAuthority(effect),
      actionable: false,
      offeredActions: immutablePresentationList(const [
        DeviceReplacementAction.refreshRemoteWorkState,
      ]),
      reasonCode: reason,
    );
  }

  /// Why the review cannot be confirmed yet, or null when it can.
  static String? eraseConfirmationRefusal(
    DeviceReplacementProjection projection,
  ) {
    final review = projection.eraseReview;
    if (!review.reviewPresented ||
        !review.requiresExplicitConfirmation ||
        !review.requiresNativeAuthentication ||
        review.targetEndpointId.isEmpty ||
        review.targetDeviceLabel.isEmpty ||
        review.affectedDataCategoryLabels.isEmpty ||
        review.consequenceStatement != deviceAppOnlyEraseConsequenceStatement ||
        !review.executesAfterReconnect ||
        review.postReconnectStatement !=
            deviceAppOnlyErasePostReconnectStatement) {
      return eraseRefusalReviewNotExplicit;
    }
    if (!review.confirmed) {
      return eraseRefusalNotConfirmed;
    }
    // An ordinary signed-in session is recorded and never accepted here.
    if (!review.nativeAuthenticationPresent) {
      return eraseRefusalNativeAuthenticationMissing;
    }
    if (projection.authority.activation != DeviceEndpointActivation.active ||
        projection.authority.outboundAuthority !=
            DeviceOutboundAuthoritySource.package ||
        projection.authority.identityRotationEpoch !=
            projection.authority.authorizedRotationEpoch ||
        projection.identityRevocation.revoked) {
      return eraseRefusalOutboundNotAuthorized;
    }
    return null;
  }

  /// The confirmation record to submit, or null when the review is not
  /// submittable.
  static DeviceEraseConfirmation? eraseConfirmation(
    DeviceReplacementProjection projection,
  ) {
    if (eraseConfirmationRefusal(projection) != null) return null;
    final review = projection.eraseReview;
    return DeviceEraseConfirmation(
      targetEndpointId: review.targetEndpointId,
      targetDeviceLabel: review.targetDeviceLabel,
      affectedDataCategoryLabels: review.affectedDataCategoryLabels,
      consequenceStatement: review.consequenceStatement,
      postReconnectStatement: review.postReconnectStatement,
      executesAfterReconnect: review.executesAfterReconnect,
      scopeEntryCount: review.scopeEntryCount,
    );
  }
}
