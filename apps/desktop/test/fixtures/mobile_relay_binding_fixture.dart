import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/contracts/generated/secure_mesh.g.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_binding.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_effect.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_intent.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_projection.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

typedef MobileRelayIntentHandler =
    void Function(MobileRelayIntent intent, MobileRelayBindingFixture fixture);

final class MobileRelayBindingFixture {
  MobileRelayBindingFixture({
    MobileRelayProjection? projection,
    MobileRelayIntentHandler? onIntent,
  }) : projection = MobileRelayProjectionFixture(
         projection ?? mobileRelayProjectionFixture(),
       ),
       effects = MobileRelayEffectFixture() {
    intents = RecordingMobileRelayIntents((intent) {
      onIntent?.call(intent, this);
    });
    binding = MobileRelayBinding(
      projection: this.projection,
      intents: intents,
      effects: effects,
    );
  }

  final MobileRelayProjectionFixture projection;
  final MobileRelayEffectFixture effects;
  late final RecordingMobileRelayIntents intents;
  late final MobileRelayBinding binding;

  void publish(MobileRelayProjection value) => projection.publish(value);

  Future<void> dispose() async {
    await projection.dispose();
    await effects.dispose();
  }
}

final class MobileRelayProjectionFixture
    implements ProjectionSource<MobileRelayProjection> {
  MobileRelayProjectionFixture(this._current);

  final StreamController<ProjectionUpdate<MobileRelayProjection>> _changes =
      StreamController<ProjectionUpdate<MobileRelayProjection>>.broadcast(
        sync: true,
      );
  MobileRelayProjection _current;

  @override
  MobileRelayProjection get current => _current;

  @override
  Stream<ProjectionUpdate<MobileRelayProjection>> get changes =>
      _changes.stream;

  void publish(MobileRelayProjection value) {
    _current = value;
    _changes.add(ProjectionUpdate(value));
  }

  Future<void> dispose() => _closeBroadcastController(_changes);
}

final class RecordingMobileRelayIntents
    implements IntentSink<MobileRelayIntent> {
  RecordingMobileRelayIntents([this._onIntent]);

  final void Function(MobileRelayIntent intent)? _onIntent;
  final List<MobileRelayIntent> values = [];

  @override
  void send(MobileRelayIntent intent) {
    values.add(intent);
    _onIntent?.call(intent);
  }
}

final class MobileRelayEffectFixture
    implements EffectSource<MobileRelayEffect> {
  final StreamController<MobileRelayEffect> _effects =
      StreamController<MobileRelayEffect>.broadcast(sync: true);

  @override
  Stream<MobileRelayEffect> get effects => _effects.stream;

  void add(MobileRelayEffect effect) => _effects.add(effect);

  Future<void> dispose() => _closeBroadcastController(_effects);
}

MobileRelayProjection mobileRelayProjectionFixture({
  List<RelayPeerProjection> peers = const [],
  List<RelayApprovalProjection> approvals = const [],
  List<RelayTransferProjection> transfers = const [],
  String pairingCode = '',
  String pairingInvite = '',
  String pairingId = '',
  String pairingExpiresLabel = '',
  String stationLabel = '',
  bool paired = false,
  bool busy = false,
  bool polling = false,
  bool mobileRuntime = false,
  bool stationConfigured = false,
  bool authorizationRequired = false,
  String draftTransferId = '',
  RelayTrustProjection? trust,
  SecureMeshCapabilityProjection? secureMeshCapabilities,
  List<String> homeEntryOrder = const [],
  List<String> pinnedHomeEntryIds = const [],
  PresentationPhase phase = PresentationPhase.ready,
  PresentationNotice? notice,
}) => MobileRelayProjection(
  peers: peers,
  approvals: approvals,
  transfers: transfers,
  pairingCode: pairingCode,
  pairingInvite: pairingInvite,
  pairingId: pairingId,
  pairingExpiresLabel: pairingExpiresLabel,
  stationLabel: stationLabel,
  paired: paired,
  busy: busy,
  polling: polling,
  mobileRuntime: mobileRuntime,
  stationConfigured: stationConfigured,
  authorizationRequired: authorizationRequired,
  draftTransferId: draftTransferId,
  trust: trust,
  secureMeshCapabilities: secureMeshCapabilities,
  homeEntryOrder: homeEntryOrder,
  pinnedHomeEntryIds: pinnedHomeEntryIds,
  phase: phase,
  notice: notice,
);

Future<void> _closeBroadcastController<T>(StreamController<T> controller) {
  if (!controller.hasListener) controller.stream.listen(null);
  return controller.close();
}
