import 'package:flutter/services.dart';

/// The macOS engine does not yet expose NSWorkspace's Reduce Motion setting.
/// The Runner sends its current value when subscribed and on every change.
final class MacosReduceMotionChannel {
  const MacosReduceMotionChannel();

  static const channelName = 'licoup/accessibility/reduce_motion';

  Stream<bool> get changes => const EventChannel(
    channelName,
  ).receiveBroadcastStream().cast<bool>().distinct();
}
