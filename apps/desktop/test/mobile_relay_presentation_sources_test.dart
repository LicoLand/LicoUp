import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/contracts/generated/secure_mesh.g.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_inputs.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_projection.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';
import 'package:licoup/src/projections/mobile_relay/mobile_relay_presentation_sources.dart';

import 'fixtures/mobile_relay_binding_fixture.dart';
import 'fixtures/secure_mesh_capability_projection.dart';

void main() {
  test('every region opens with its own slice of the projection', () async {
    final upstream = _MutableProjectionSource(
      mobileRelayProjectionFixture(
        peers: const [
          RelayPeerProjection(
            id: 'device-1',
            displayName: 'Workstation',
            connected: true,
            selected: true,
          ),
        ],
        approvals: const [
          RelayApprovalProjection(
            id: 'operation-1',
            capabilityLabel: 'local_effect',
            requesterLabel: 'claude-code',
            resolvable: true,
          ),
        ],
        transfers: const [
          RelayTransferProjection(
            id: 'transfer-1',
            fileLabel: 'notes.txt',
            destinationLabel: '/tmp/received',
            progress: 0.5,
            stateLabel: 'evaluating',
            chunkCount: 2,
          ),
        ],
        pairingCode: 'CODE-1',
        pairingInvite: 'opaque-invite',
        pairingId: 'pair-1',
        pairingExpiresLabel: '2030-01-01T00:00:00Z',
        stationLabel: 'https://station.example.test',
        paired: true,
        busy: true,
        polling: true,
        mobileRuntime: true,
        stationConfigured: true,
        trust: _trustFixture,
        secureMeshCapabilities: _capabilitiesFixture,
        homeEntryOrder: const ['device:device-1'],
        pinnedHomeEntryIds: const ['device:device-1'],
      ),
    );
    final regions = await _openRegions(upstream);
    addTearDown(regions.dispose);

    expect(
      regions.pairing.initial.value,
      MobileRelayPairingInputs(
        pairingCode: 'CODE-1',
        pairingInvite: 'opaque-invite',
        pairingId: 'pair-1',
        pairingExpiresLabel: '2030-01-01T00:00:00Z',
        stationLabel: 'https://station.example.test',
        paired: true,
        busy: true,
        polling: true,
        mobileRuntime: true,
        stationConfigured: true,
        authorizationRequired: false,
        phase: PresentationPhase.ready,
        notice: null,
      ),
    );
    expect(regions.trust.initial.value.trust, _trustFixture);
    expect(regions.approvals.initial.value.approvals.single.id, 'operation-1');
    expect(regions.approvals.initial.value.busy, isTrue);
    expect(regions.transfers.initial.value.transfers.single.id, 'transfer-1');
    expect(regions.transfers.initial.value.draft, isNull);
    expect(
      regions.capabilities.initial.value.capabilities,
      same(_capabilitiesFixture),
    );
    expect(regions.home.initial.value.peers.single.id, 'device-1');
    expect(regions.home.initial.value.homeEntryOrder, const [
      'device:device-1',
    ]);
    expect(regions.home.initial.value.pinnedHomeEntryIds, const [
      'device:device-1',
    ]);
    expect(regions.home.initial.value.mobileRuntime, isTrue);
    expect(regions.home.initial.fieldGroup, mobileRelayHomeRegion.fieldGroup);
    expect(
      regions.pairing.initial.fieldGroup,
      mobileRelayPairingRegion.fieldGroup,
    );
  });

  test('a change outside a region slice emits nothing', () async {
    final upstream = _MutableProjectionSource(
      mobileRelayProjectionFixture(
        stationLabel: 'https://station.example.test',
      ),
    );
    final regions = await _openRegions(upstream);
    addTearDown(regions.dispose);

    upstream.publish(
      mobileRelayProjectionFixture(
        stationLabel: 'https://station.example.test',
        pairingCode: 'CODE-2',
      ),
    );
    upstream.publish(
      mobileRelayProjectionFixture(
        stationLabel: 'https://station.example.test',
        pairingCode: 'CODE-2',
      ),
    );
    await _flush();

    expect(regions.pairing.changes, hasLength(1));
    expect(regions.pairing.initial.value.pairingCode, isEmpty);
    expect(regions.pairing.latest.value.pairingCode, 'CODE-2');
    expect(regions.trust.changes, isEmpty);
    expect(regions.approvals.changes, isEmpty);
    expect(regions.transfers.changes, isEmpty);
    expect(regions.capabilities.changes, isEmpty);
    expect(regions.home.changes, isEmpty);
  });

  test('a peers-only change reaches home and nothing else', () async {
    final upstream = _MutableProjectionSource(mobileRelayProjectionFixture());
    final regions = await _openRegions(upstream);
    addTearDown(regions.dispose);

    upstream.publish(
      mobileRelayProjectionFixture(
        peers: const [
          RelayPeerProjection(
            id: 'device-1',
            displayName: 'Workstation',
            connected: true,
            selected: true,
          ),
        ],
        homeEntryOrder: const ['device:device-1'],
      ),
    );
    await _flush();

    expect(regions.home.changes, hasLength(1));
    expect(regions.home.latest.value.peers.single.id, 'device-1');
    expect(regions.pairing.changes, isEmpty);
    expect(regions.trust.changes, isEmpty);
    expect(regions.approvals.changes, isEmpty);
    expect(regions.transfers.changes, isEmpty);
    expect(regions.capabilities.changes, isEmpty);
  });

  test('changes carry base-matched monotonic single-member groups', () async {
    final upstream = _MutableProjectionSource(mobileRelayProjectionFixture());
    final region = _Region(mobileRelayHomeRegion, upstream);
    addTearDown(region.dispose);

    await region.open();
    final initial = region.initial;
    upstream.publish(
      mobileRelayProjectionFixture(homeEntryOrder: const ['device:device-1']),
    );
    upstream.publish(
      mobileRelayProjectionFixture(
        homeEntryOrder: const ['device:device-1'],
        pinnedHomeEntryIds: const ['device:device-1'],
      ),
    );
    await _flush();

    expect(region.changes, hasLength(2));
    var base = initial.position;
    for (final change in region.changes) {
      expect(change.group.changed, hasLength(1));
      expect(
        change.group.changed.single,
        ChangedFieldGroup.of(mobileRelayHomeRegion.fieldGroup),
      );
      expect(change.group.position, change.snapshot.position);
      expect(change.group.affects(mobileRelayHomeRegion.fieldGroup), isTrue);
      expect(change.snapshot.epoch, initial.epoch);
      expect(change.snapshot.fieldGroup, mobileRelayHomeRegion.fieldGroup);
      expect(change.snapshot.consistencyGroup, change.group);
      expect(change.base, base);
      expect(change.snapshot.position.isAfter(base), isTrue);
      expect(change.trace, isNull);
      base = change.snapshot.position;
    }
    expect(
      region.changes[1].snapshot.position.compare(
        region.changes[0].snapshot.position,
      ),
      VersionRelation.newer,
    );
  });

  test('the upstream subscription is released and can be re-opened', () async {
    final upstream = _MutableProjectionSource(
      mobileRelayProjectionFixture(stationLabel: 'https://first.example.test'),
    );
    final region = _Region(mobileRelayPairingRegion, upstream);
    addTearDown(region.dispose);

    await region.open();
    final first = region.initial;
    expect(first.value.stationLabel, 'https://first.example.test');
    expect(upstream.hasListener, isTrue);

    await region.close();
    await _flush();
    expect(upstream.hasListener, isFalse);

    upstream.publish(
      mobileRelayProjectionFixture(stationLabel: 'https://second.example.test'),
    );
    await _flush();
    expect(region.changes, isEmpty);

    await region.open();
    final second = region.initial;
    expect(second.value.stationLabel, 'https://second.example.test');
    expect(upstream.hasListener, isTrue);
    expect(second.position.compare(first.position), VersionRelation.newer);

    upstream.publish(
      mobileRelayProjectionFixture(
        stationLabel: 'https://second.example.test',
        paired: true,
      ),
    );
    await _flush();
    expect(region.changes, hasLength(1));
    expect(region.changes.single.base, second.position);
  });

  test('a disposed region source refuses to open', () async {
    final upstream = _MutableProjectionSource(mobileRelayProjectionFixture());
    final region = _Region(mobileRelayTrustRegion, upstream);

    await region.dispose();
    await expectLater(region.source.open(), throwsStateError);
  });
}

final _trustFixture = RelayTrustProjection(
  schemaVersion: 'licoup.secure-mesh.device-trust-presentation.v1',
  protocolVersion: 'licoup.secure-mesh.device-trust.v2',
  localFingerprint: 'local-fingerprint',
  peerFingerprint: 'peer-fingerprint',
  safetyNumberGroups: const ['00001', '00002'],
  qrPayload: 'licoup-trust-qr',
  trustState: 'verified',
  verificationMethod: 'pairing_claim_proof',
  verified: true,
);

final _capabilitiesFixture = SecureMeshCapabilityProjection.fromJson(
  activeSecureMeshCapabilityProjectionFixture(),
);

Future<void> _flush() => Future<void>.delayed(Duration.zero);

final class _Region<T> {
  _Region(this.region, this.upstream);

  final MobileRelayPresentationRegion<T> region;
  final _MutableProjectionSource upstream;
  final List<SourceChange<T>> changes = <SourceChange<T>>[];
  late final MobileRelayRegionPresentationSource<T> source =
      mobileRelayRegionPresentationSource(region, upstream);
  late ResourceSnapshot<T> initial;
  late ResourceSnapshot<T> latest;
  StreamSubscription<SourceChange<T>>? _subscription;

  ResourceFieldGroup<T> get fieldGroup => region.fieldGroup;

  Future<void> open() async {
    final observation = await source.open();
    initial = observation.initial;
    latest = observation.initial;
    _subscription = observation.changes.listen((change) {
      changes.add(change);
      latest = change.snapshot;
    });
  }

  Future<void> close() async {
    await _subscription?.cancel();
    _subscription = null;
  }

  Future<void> dispose() async {
    await close();
    await source.dispose();
  }
}

final class _Regions {
  _Regions(this.upstream)
    : pairing = _Region(mobileRelayPairingRegion, upstream),
      trust = _Region(mobileRelayTrustRegion, upstream),
      approvals = _Region(mobileRelayApprovalsRegion, upstream),
      transfers = _Region(mobileRelayTransfersRegion, upstream),
      capabilities = _Region(mobileRelayCapabilitiesRegion, upstream),
      home = _Region(mobileRelayHomeRegion, upstream);

  final _MutableProjectionSource upstream;
  final _Region<MobileRelayPairingInputs> pairing;
  final _Region<MobileRelayTrustInputs> trust;
  final _Region<MobileRelayApprovalsInputs> approvals;
  final _Region<MobileRelayTransfersInputs> transfers;
  final _Region<MobileRelayCapabilitiesInputs> capabilities;
  final _Region<MobileRelayHomeInputs> home;

  Future<void> dispose() async {
    await pairing.dispose();
    await trust.dispose();
    await approvals.dispose();
    await transfers.dispose();
    await capabilities.dispose();
    await home.dispose();
  }
}

Future<_Regions> _openRegions(_MutableProjectionSource upstream) async {
  final regions = _Regions(upstream);
  await regions.pairing.open();
  await regions.trust.open();
  await regions.approvals.open();
  await regions.transfers.open();
  await regions.capabilities.open();
  await regions.home.open();
  return regions;
}

final class _MutableProjectionSource
    implements ProjectionSource<MobileRelayProjection> {
  _MutableProjectionSource(this._current)
    : _controller =
          StreamController<ProjectionUpdate<MobileRelayProjection>>.broadcast(
            sync: true,
          );

  final StreamController<ProjectionUpdate<MobileRelayProjection>> _controller;
  MobileRelayProjection _current;

  bool get hasListener => _controller.hasListener;

  @override
  MobileRelayProjection get current => _current;

  @override
  Stream<ProjectionUpdate<MobileRelayProjection>> get changes =>
      _controller.stream;

  void publish(MobileRelayProjection value) {
    _current = value;
    _controller.add(ProjectionUpdate(value));
  }
}
