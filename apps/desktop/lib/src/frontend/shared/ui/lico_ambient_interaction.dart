import 'package:flutter/material.dart';

/// Ambient layers read the notifier directly, so updates repaint the effect
/// without rebuilding widgets. Owned and disposed by `LicoWindowGround`.
final class LicoAmbientInteraction {
  LicoAmbientInteraction();

  /// Pointer position in ground coordinates, or null when not hovering.
  final ValueNotifier<Offset?> pointer = ValueNotifier<Offset?>(null);

  void dispose() {
    pointer.dispose();
  }
}
