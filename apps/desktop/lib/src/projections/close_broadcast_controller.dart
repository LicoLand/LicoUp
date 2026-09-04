import 'dart:async';

/// Closes a broadcast controller with a completion path even when no renderer
/// ever observed it. Dart otherwise has no listener to consume the done event.
Future<void> closeBroadcastController<T>(StreamController<T> controller) {
  if (!controller.hasListener) {
    controller.stream.listen(null);
  }
  return controller.close();
}
