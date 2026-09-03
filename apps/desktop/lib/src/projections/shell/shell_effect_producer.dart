import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/presentation/shell/shell_effect.dart';

final class ShellEffectProducer implements EffectSource<ShellEffect> {
  final StreamController<ShellEffect> _effects =
      StreamController<ShellEffect>.broadcast(sync: true);
  bool _disposed = false;

  @override
  Stream<ShellEffect> get effects => _effects.stream;

  void emit(ShellEffect effect) {
    if (!_disposed) _effects.add(effect);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _effects.close();
  }
}
