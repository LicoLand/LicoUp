import 'dart:async';

/// Deterministically closes a broadcast projection lane.
Future<void> closeBroadcastController<T>(StreamController<T> controller) =>
    controller.close();
