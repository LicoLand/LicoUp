import 'package:flutter/services.dart';

import 'package:licoup/src/contracts/presentation/window_chrome_models.dart';

export 'package:licoup/src/contracts/presentation/window_chrome_models.dart'
    show TrafficLightClusterEdges;

/// Channel name shared with `macos/Runner/MainFlutterWindow.swift`.
const String windowChromeChannelName = 'licoup/window_chrome';

/// macOS window-chrome bridge backing the hidden-titlebar desktop shell.
///
/// Every call degrades to a no-op when no native handler is registered, which
/// keeps non-macOS shells and widget tests safe without platform branching at
/// the call site.

final class WindowChromeChannel {
  const WindowChromeChannel({required MethodChannel channel})
    : _channel = channel;

  static const WindowChromeChannel instance = WindowChromeChannel(
    channel: MethodChannel(windowChromeChannelName),
  );

  final MethodChannel _channel;

  /// Hands the in-flight mouse drag to the native window so the window follows
  /// the pointer until mouse-up, like a drag on a native title bar.
  Future<void> dragWindow() async {
    try {
      await _channel.invokeMethod<void>('dragWindow');
    } on MissingPluginException {
      // No native window chrome is registered on this platform.
    }
  }

  /// Toggles the standard macOS zoom state of the window.
  Future<void> toggleZoom() async {
    try {
      await _channel.invokeMethod<void>('toggleZoom');
    } on MissingPluginException {
      // No native window chrome is registered on this platform.
    }
  }

  /// Moves the macOS traffic lights into the layout-reported [rect] — window
  /// logical points, y down from the window content's top-left. Passing null
  /// restores the default 48pt top-band placement.
  ///
  /// Resolves to the light cluster's edges (close button's minX, zoom
  /// button's maxX) in the same logical coordinates, or null when the
  /// lights are unavailable or no native handler is registered. The native window keeps
  /// the last reported rect, so shells can report on every layout change
  /// without ordering guarantees against alignment.
  Future<TrafficLightClusterEdges?> setTrafficLightAnchor(Rect? rect) async {
    final List<double>? arguments = rect == null
        ? null
        : <double>[rect.left, rect.top, rect.width, rect.height];
    try {
      final result = await _channel.invokeMethod<Object?>(
        'setTrafficLightAnchor',
        arguments,
      );
      if (result is! Map) {
        return null;
      }
      final leading = (result['leading'] as num?)?.toDouble();
      final trailing = (result['trailing'] as num?)?.toDouble();
      if (leading == null || trailing == null) {
        return null;
      }
      return (leading: leading, trailing: trailing);
    } on MissingPluginException {
      // No native window chrome is registered on this platform.
      return null;
    }
  }

  /// Restores the default 48pt top-band traffic-light placement.
  Future<void> clearTrafficLightAnchor() async {
    await setTrafficLightAnchor(null);
  }
}
