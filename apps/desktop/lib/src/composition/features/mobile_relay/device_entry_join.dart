import 'package:licoup/src/application/features/mobile_relay/policy/device_replacement_policy.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_binding.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';
import 'package:licoup/src/projections/mobile_relay/device_replacement_projection_source.dart';

/// What the host resolved about the optional endpoint collaboration package.
///
/// Mirrors `EndpointCollaborationAvailability` in
/// `crates/licoup-native/src/platform/extension_packages/endpoint_collaboration.rs`
/// and `Availability` in `components/endpoint-collaboration/src/lib.rs`. Absent
/// and disabled are answers, not an absence of an answer: a caller that only
/// knows how to hide a surface cannot report either of them.
enum EndpointCollaborationState {
  active,
  disabled,
  capabilityUndeclared,
  missing,
  unreadable,
}

/// One resolved answer, with the installed version when there is one.
final class EndpointCollaborationAvailability {
  const EndpointCollaborationAvailability._(this.state, this.version);

  const EndpointCollaborationAvailability.active(String version)
    : this._(EndpointCollaborationState.active, version);

  const EndpointCollaborationAvailability.disabled(String version)
    : this._(EndpointCollaborationState.disabled, version);

  const EndpointCollaborationAvailability.capabilityUndeclared(String version)
    : this._(EndpointCollaborationState.capabilityUndeclared, version);

  const EndpointCollaborationAvailability.missing()
    : this._(EndpointCollaborationState.missing, '');

  const EndpointCollaborationAvailability.unreadable()
    : this._(EndpointCollaborationState.unreadable, '');

  final EndpointCollaborationState state;
  final String version;

  /// Whether this client may emit outbound endpoint traffic.
  bool get permitsOutbound => state == EndpointCollaborationState.active;

  /// Why outbound endpoint traffic is refused, or null while it is permitted.
  EndpointOutboundRefusal? get refusal => EndpointOutboundRefusal.of(this);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EndpointCollaborationAvailability &&
          other.state == state &&
          other.version == version;

  @override
  int get hashCode => Object.hash(state, version);
}

/// Why outbound endpoint traffic is refused. Each refusal is a stable reason
/// this client publishes verbatim.
enum EndpointOutboundRefusal {
  packageMissing,
  packageDisabled,
  capabilityUndeclared,
  storeUnreadable;

  /// The reason string the native owner publishes for this refusal.
  String get reason => switch (this) {
    EndpointOutboundRefusal.packageMissing =>
      'endpoint_collaboration_package_absent',
    EndpointOutboundRefusal.packageDisabled =>
      'endpoint_collaboration_package_disabled',
    EndpointOutboundRefusal.capabilityUndeclared =>
      'endpoint_collaboration_capability_undeclared',
    EndpointOutboundRefusal.storeUnreadable =>
      'endpoint_collaboration_store_unreadable',
  };

  /// The refusal one resolved availability produces, or null while it permits.
  static EndpointOutboundRefusal? of(EndpointCollaborationAvailability value) =>
      switch (value.state) {
        EndpointCollaborationState.active => null,
        EndpointCollaborationState.disabled =>
          EndpointOutboundRefusal.packageDisabled,
        EndpointCollaborationState.capabilityUndeclared =>
          EndpointOutboundRefusal.capabilityUndeclared,
        EndpointCollaborationState.missing =>
          EndpointOutboundRefusal.packageMissing,
        EndpointCollaborationState.unreadable =>
          EndpointOutboundRefusal.storeUnreadable,
      };
}

/// The action that would make the capability usable again.
enum EndpointCollaborationRecoveryAction {
  none,
  installPackage,
  enablePackage,
  installCapableVersion,
  repairStore,
}

/// What a client in this state reports to its user.
final class EndpointCollaborationRecovery {
  const EndpointCollaborationRecovery({
    required this.localClientUsable,
    required this.capabilityAvailable,
    required this.refusal,
    required this.action,
  });

  /// Constant: the local client, its conversations, its running work and its
  /// history never depend on this optional package.
  final bool localClientUsable;

  final bool capabilityAvailable;
  final EndpointOutboundRefusal? refusal;
  final EndpointCollaborationRecoveryAction action;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EndpointCollaborationRecovery &&
          other.localClientUsable == localClientUsable &&
          other.capabilityAvailable == capabilityAvailable &&
          other.refusal == refusal &&
          other.action == action;

  @override
  int get hashCode =>
      Object.hash(localClientUsable, capabilityAvailable, refusal, action);
}

/// Read-only port over the host's resolution of the optional package.
///
/// The host resolves it today, but no Dart bridge carries that answer, so the
/// shipped composition is [UnboundEndpointCollaborationAvailability] and tests
/// substitute a synthetic resolution.
abstract interface class EndpointCollaborationAvailabilityPort {
  EndpointCollaborationAvailability get availability;
}

/// The resolution of a client with no bridge to the host's package store.
///
/// `Missing` is the fail-closed answer the native owner itself documents for an
/// answer it cannot produce ("it resolves like `Missing` for the caller"), so a
/// client that never asked reports the absent package rather than claiming an
/// installed one.
final class UnboundEndpointCollaborationAvailability
    implements EndpointCollaborationAvailabilityPort {
  const UnboundEndpointCollaborationAvailability();

  @override
  EndpointCollaborationAvailability get availability =>
      const EndpointCollaborationAvailability.missing();
}

/// Why the device replacement and control entry refused one action.
///
/// Every member is produced by [DeviceEntryJoin.admit]. The vocabulary carries
/// no member that would re-drive an effect: the shipped action vocabulary has no
/// such action at all, so a refusal for one would be unreachable.
enum DeviceReplacementControlRefusal {
  /// The optional package does not own this client's outbound path.
  packageUnavailable,

  /// No native replacement or control owner is implemented in this client.
  nativeEntryAbsent,

  /// The current endpoint authority does not cover this action.
  endpointNotAuthorized,

  /// The endpoint identity is revoked, and revocation is absorbing.
  identityRevoked,

  /// The review the action needs was not confirmed.
  reviewNotConfirmed,

  /// The platform's own authentication is absent.
  nativeAuthenticationMissing,
}

/// The admission one control entry gave one action.
final class DeviceReplacementControlAdmission {
  const DeviceReplacementControlAdmission.admitted()
    : admitted = true,
      refusal = null;

  const DeviceReplacementControlAdmission.refused(
    DeviceReplacementControlRefusal this.refusal,
  ) : admitted = false;

  final bool admitted;
  final DeviceReplacementControlRefusal? refusal;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DeviceReplacementControlAdmission &&
          other.admitted == admitted &&
          other.refusal == refusal;

  @override
  int get hashCode => Object.hash(admitted, refusal);
}

/// The device replacement and remote control entry.
///
/// NOT IMPLEMENTED IN THIS TREE. The native owners that would perform a device
/// transfer, authorize a replacement or observe a remote stop are absent: the
/// `control` module `components/endpoint-collaboration/control/src/lib.rs`
/// declares is not present, and no `licoup-native` command drives a replacement.
/// This port is therefore a composition-boundary seam, and the shipped
/// implementation is [AbsentDeviceReplacementControl], which refuses every
/// action instead of offering a control it cannot drive. Tests supply a
/// synthetic admission.
abstract interface class DeviceReplacementControlPort {
  DeviceReplacementControlAdmission admit(DeviceReplacementAction action);
}

/// The control entry of a client that has none.
final class AbsentDeviceReplacementControl
    implements DeviceReplacementControlPort {
  const AbsentDeviceReplacementControl();

  @override
  DeviceReplacementControlAdmission admit(DeviceReplacementAction action) =>
      const DeviceReplacementControlAdmission.refused(
        DeviceReplacementControlRefusal.nativeEntryAbsent,
      );
}

/// The production composition entry that joins the optional endpoint
/// collaboration package, the device replacement and control entry, and the
/// existing mobile relay feature composition.
///
/// Two rules are the whole reason this join exists:
///
/// * **The package gate is a cut, not a hidden control.** While the resolved
///   availability refuses outbound endpoint traffic, this join offers no
///   replacement or control intent at all and publishes the owner's own refusal
///   reason beside the action that would recover it.
/// * **Nothing here upgrades one fact into another.** The join reads the cleanup
///   badge, the erase confirmation and the offered intents through the pure
///   policy, so a file-stage receipt never becomes an erased device, a lost
///   receipt never renews an old device's admission, and an unknown remote
///   effect is never re-driven.
final class DeviceEntryJoin {
  DeviceEntryJoin({
    required EndpointCollaborationAvailabilityPort package,
    required DeviceReplacementControlPort control,
    required this.relay,
    required this.deviceState,
  }) : _package = package,
       _control = control;

  /// The join the shipped client runs.
  ///
  /// It reports the package as missing because this client has no bridge to the
  /// host's resolution, and it refuses every device action because the native
  /// replacement and control owners are not implemented. The relay half is the
  /// mounted feature's own binding, published unchanged.
  factory DeviceEntryJoin.production({
    required MobileRelayBinding relay,
    EndpointCollaborationAvailabilityPort package =
        const UnboundEndpointCollaborationAvailability(),
    DeviceReplacementControlPort control =
        const AbsentDeviceReplacementControl(),
    DeviceReplacementProjectionSource? deviceState,
  }) => DeviceEntryJoin(
    package: package,
    control: control,
    relay: relay,
    deviceState: deviceState ?? DeviceReplacementProjectionSource.unobserved(),
  );

  /// Actions that drive another endpoint's device state. Reviewing facts, and
  /// re-reading them, are not on this list.
  static const Set<DeviceReplacementAction> replacementControlActions =
      <DeviceReplacementAction>{
        DeviceReplacementAction.submitEraseConfirmation,
        DeviceReplacementAction.requestRemoteStop,
      };

  final EndpointCollaborationAvailabilityPort _package;
  final DeviceReplacementControlPort _control;

  /// The existing mobile relay feature composition's own binding, published
  /// unchanged so this join adds no second relay surface and no second owner.
  final MobileRelayBinding relay;

  /// The separate device facts, re-read on restart and reconnect.
  final DeviceReplacementProjectionSource deviceState;

  /// The host's answer about the optional package.
  EndpointCollaborationAvailability get availability => _package.availability;

  /// The truthful report for a client whose capability is unavailable.
  EndpointCollaborationRecovery get recovery {
    final refusal = availability.refusal;
    return EndpointCollaborationRecovery(
      localClientUsable: true,
      capabilityAvailable: availability.permitsOutbound,
      refusal: refusal,
      action: switch (availability.state) {
        EndpointCollaborationState.active =>
          EndpointCollaborationRecoveryAction.none,
        EndpointCollaborationState.disabled =>
          EndpointCollaborationRecoveryAction.enablePackage,
        EndpointCollaborationState.capabilityUndeclared =>
          EndpointCollaborationRecoveryAction.installCapableVersion,
        EndpointCollaborationState.missing =>
          EndpointCollaborationRecoveryAction.installPackage,
        EndpointCollaborationState.unreadable =>
          EndpointCollaborationRecoveryAction.repairStore,
      },
    );
  }

  /// The stable reason outbound endpoint traffic is refused, or null.
  EndpointOutboundRefusal? get refusal => availability.refusal;

  /// Whether the optional capability is usable in this client.
  bool get capabilityAvailable => availability.permitsOutbound;

  /// The replacement and control actions offered now.
  ///
  /// Empty while the package refuses outbound endpoint traffic, and otherwise
  /// exactly the actions the current facts authorize and this join admits.
  List<DeviceReplacementAction> get offeredActions {
    if (!capabilityAvailable) return immutablePresentationList(const []);
    return immutablePresentationList([
      for (final action in DeviceReplacementPolicy.offeredActions(
        deviceState.current,
      ))
        if (admit(action).admitted) action,
    ]);
  }

  /// Whether anything here would drive another endpoint's device state.
  bool get offersReplacementControl =>
      offeredActions.any(replacementControlActions.contains);

  /// The admission for one action, with the package gate applied first.
  ///
  /// An action the package gate refuses is never presented to the control entry,
  /// so a disabled or unreadable package cannot reach a native owner even if one
  /// is attached later. The gates the policy already decided are re-stated as
  /// this entry's own refusals, so a caller learns which fact refused it instead
  /// of a bare refusal.
  DeviceReplacementControlAdmission admit(DeviceReplacementAction action) {
    if (!capabilityAvailable) {
      return const DeviceReplacementControlAdmission.refused(
        DeviceReplacementControlRefusal.packageUnavailable,
      );
    }
    if (!replacementControlActions.contains(action)) {
      return _control.admit(action);
    }
    final projection = deviceState.current;
    if (projection.identityRevocation.revoked) {
      return const DeviceReplacementControlAdmission.refused(
        DeviceReplacementControlRefusal.identityRevoked,
      );
    }
    if (action == DeviceReplacementAction.submitEraseConfirmation) {
      final eraseRefusal = DeviceReplacementPolicy.eraseConfirmationRefusal(
        projection,
      );
      if (eraseRefusal == DeviceReplacementPolicy.eraseRefusalNotConfirmed) {
        return const DeviceReplacementControlAdmission.refused(
          DeviceReplacementControlRefusal.reviewNotConfirmed,
        );
      }
      if (eraseRefusal ==
          DeviceReplacementPolicy.eraseRefusalNativeAuthenticationMissing) {
        return const DeviceReplacementControlAdmission.refused(
          DeviceReplacementControlRefusal.nativeAuthenticationMissing,
        );
      }
      if (eraseRefusal ==
          DeviceReplacementPolicy.eraseRefusalOutboundNotAuthorized) {
        return const DeviceReplacementControlAdmission.refused(
          DeviceReplacementControlRefusal.endpointNotAuthorized,
        );
      }
    }
    return _control.admit(action);
  }

  /// The truthful cleanup state and the only badge it may carry.
  DeviceCleanupPresentation get cleanupPresentation =>
      DeviceReplacementPolicy.cleanupPresentation(
        deviceState.current.pendingCleanup,
      );

  /// The confirmation to submit, or null when the review is not submittable or
  /// the package refuses outbound endpoint traffic.
  DeviceEraseConfirmation? get eraseConfirmation => capabilityAvailable
      ? DeviceReplacementPolicy.eraseConfirmation(deviceState.current)
      : null;

  Future<void> dispose() => deviceState.dispose();
}
