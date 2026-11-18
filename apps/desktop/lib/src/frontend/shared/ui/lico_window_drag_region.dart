import 'dart:async';

import 'package:flutter/widgets.dart';

import 'package:licoup/src/frontend/shared/client_platform_ports.dart';

/// A transparent strip the window treats as title-bar chrome: panning hands
/// the drag to the host window and a double tap toggles zoom, mirroring a
/// native title bar. [HitTestBehavior.translucent] keeps controls inside
/// the strip interactive; the ports are no-ops where the host registers no
/// window chrome.
final class LicoWindowDragRegion extends StatelessWidget {
  const LicoWindowDragRegion({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => unawaited(ClientPlatformPorts.dragWindow()),
      onDoubleTap: () => unawaited(ClientPlatformPorts.toggleZoom()),
      child: child,
    );
  }
}
