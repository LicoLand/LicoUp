import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/presentation/mobile_relay/mobile_relay_effect.dart';
import 'package:licoup/src/projections/close_broadcast_controller.dart';

final class MobileRelayEffectProducer
    implements EffectSource<MobileRelayEffect> {
  final StreamController<MobileRelayEffect> _controller =
      StreamController<MobileRelayEffect>.broadcast(sync: true);
  bool _disposed = false;

  @override
  Stream<MobileRelayEffect> get effects => _controller.stream;

  void emit(MobileRelayEffect effect) {
    if (!_disposed) _controller.add(effect);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await closeBroadcastController(_controller);
  }
}
