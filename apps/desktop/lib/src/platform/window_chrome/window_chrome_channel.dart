import 'package:flutter/services.dart';

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
}
