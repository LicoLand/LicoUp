import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/presentation/mobile_relay/mobile_relay_inputs.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_projection.dart';

/// One typed mobile relay region: its stable resource identity and the pure
/// slice read that computes the region value from the feature projection.
final class MobileRelayPresentationRegion<T> {
  const MobileRelayPresentationRegion({
    required this.fieldGroup,
    required this.read,
  });

  final ResourceFieldGroup<T> fieldGroup;
  final T Function(MobileRelayProjection projection) read;
}

/// Stable resource identity for the pairing/status region.
final mobileRelayPairingRegion =
    MobileRelayPresentationRegion<MobileRelayPairingInputs>(
      fieldGroup: _regionFieldGroup('pairing'),
      read: MobileRelayPairingInputs.fromProjection,
    );

/// Stable resource identity for the device-trust region.
final mobileRelayTrustRegion =
    MobileRelayPresentationRegion<MobileRelayTrustInputs>(
      fieldGroup: _regionFieldGroup('trust'),
      read: MobileRelayTrustInputs.fromProjection,
    );

/// Stable resource identity for the remote-approval region.
final mobileRelayApprovalsRegion =
    MobileRelayPresentationRegion<MobileRelayApprovalsInputs>(
      fieldGroup: _regionFieldGroup('approvals'),
      read: MobileRelayApprovalsInputs.fromProjection,
    );

/// Stable resource identity for the file-sync transfer region.
final mobileRelayTransfersRegion =
    MobileRelayPresentationRegion<MobileRelayTransfersInputs>(
      fieldGroup: _regionFieldGroup('transfers'),
      read: MobileRelayTransfersInputs.fromProjection,
    );

/// Stable resource identity for the negotiated-capability region.
final mobileRelayCapabilitiesRegion =
    MobileRelayPresentationRegion<MobileRelayCapabilitiesInputs>(
      fieldGroup: _regionFieldGroup('capabilities'),
      read: MobileRelayCapabilitiesInputs.fromProjection,
    );

/// Stable resource identity for the mobile agents home/list region.
final mobileRelayHomeRegion =
    MobileRelayPresentationRegion<MobileRelayHomeInputs>(
      fieldGroup: _regionFieldGroup('home'),
      read: MobileRelayHomeInputs.fromProjection,
    );

ResourceFieldGroup<T> _regionFieldGroup<T>(String stableKey) =>
    ResourceFieldGroup<T>(
      resource: ResourceKey(
        scope: const ResourceScope('mobile-relay'),
        stableKey: stableKey,
      ),
      name: 'inputs',
    );

int _epochCounter = 0;

/// Creates one region presentation source over the existing mobile relay
/// projection source.
MobileRelayRegionPresentationSource<T> mobileRelayRegionPresentationSource<T>(
  MobileRelayPresentationRegion<T> region,
  ProjectionSource<MobileRelayProjection> source,
) {
  return MobileRelayRegionPresentationSource<T>(
    fieldGroup: region.fieldGroup,
    source: source,
    read: region.read,
    epochId:
        'mobile-relay-${region.fieldGroup.resource.stableKey}-'
        '${_epochCounter++}',
  );
}

/// Presentation-source adapter over the mobile relay projection producer. The
/// projection source remains the single owner of the projected state; this
/// adapter re-issues only its own slice with epoch/version ordering and
/// base-matched changes for the presentation runtime.
final class MobileRelayRegionPresentationSource<T>
    implements PresentationSource<T> {
  MobileRelayRegionPresentationSource({
    required this.fieldGroup,
    required ProjectionSource<MobileRelayProjection> source,
    required T Function(MobileRelayProjection projection) read,
    required String epochId,
  }) : _source = source,
       _read = read,
       _epoch = SourceEpoch(epochId);

  @override
  final ResourceFieldGroup<T> fieldGroup;

  final ProjectionSource<MobileRelayProjection> _source;
  final T Function(MobileRelayProjection projection) _read;
  final SourceEpoch _epoch;
  final List<StreamController<SourceChange<T>>> _observations =
      <StreamController<SourceChange<T>>>[];
  int _version = 0;
  bool _disposed = false;

  @override
  Future<SourceObservation<T>> open() async {
    if (_disposed) {
      throw StateError('mobile relay region source disposed');
    }
    final position = _nextPosition();
    var installed = position;
    var value = _read(_source.current);
    final changes = StreamController<SourceChange<T>>(sync: true);
    _observations.add(changes);
    // Subscribe before reading again so no upstream update can slip between
    // the initial value and the change stream.
    final subscription = _source.changes.listen(
      (update) {
        if (changes.isClosed) return;
        final next = _read(update.value);
        if (next == value) return;
        value = next;
        final nextPosition = _nextPosition();
        final group = ConsistencyGroup(
          id: ConsistencyGroupId(
            '${fieldGroup.resource.stableKey}-${nextPosition.version.value}',
            source: SourceIdentity(
              scope: fieldGroup.resource.scope,
              stableKey: fieldGroup.resource.stableKey,
            ),
          ),
          position: nextPosition,
          changed: <ChangedFieldGroup>[ChangedFieldGroup.of(fieldGroup)],
        );
        changes.add(
          SourceChange<T>(
            snapshot: ResourceSnapshot<T>(
              fieldGroup: fieldGroup,
              epoch: nextPosition.epoch,
              version: nextPosition.version,
              value: next,
              consistencyGroup: group,
            ),
            base: installed,
            group: group,
            trace: update.trace,
          ),
        );
        installed = nextPosition;
      },
      onDone: () {
        if (!changes.isClosed) unawaited(changes.close());
      },
    );
    changes.onCancel = () async {
      _observations.remove(changes);
      await subscription.cancel();
    };
    return SourceObservation<T>(
      initial: ResourceSnapshot<T>(
        fieldGroup: fieldGroup,
        epoch: position.epoch,
        version: position.version,
        value: value,
      ),
      changes: changes.stream,
    );
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final controller in _observations.toList()) {
      _observations.remove(controller);
      if (!controller.isClosed) await controller.close();
    }
  }

  SourcePosition _nextPosition() {
    _version += 1;
    return SourcePosition(epoch: _epoch, version: SourceVersion(_version));
  }
}
