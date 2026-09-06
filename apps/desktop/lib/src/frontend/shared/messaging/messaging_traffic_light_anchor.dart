import 'dart:async';

import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/shared/client_platform_ports.dart';
import 'package:licoup/src/frontend/shared/ui/messaging_desktop_tokens.dart';

/// Invisible anchor that reserves the native traffic-light cluster zone at a
/// sidebar card's top-left and reports its rect through the window-chrome
/// channel so macOS moves the lights into it. The report fires after layout
/// whenever the rect changes; the native side keeps the last rect, so
/// destination switches that swap one anchor for another at the same
/// position never move the lights.
final class MessagingTrafficLightAnchor extends StatefulWidget {
  const MessagingTrafficLightAnchor({
    super.key,
    this.width = MessagingDesktopMetrics.trafficLightAnchorExtent,
    this.height = MessagingDesktopMetrics.trafficLightRowExtent,
  });

  final double width;
  final double height;

  @override
  State<MessagingTrafficLightAnchor> createState() =>
      _MessagingTrafficLightAnchorState();
}

final class _MessagingTrafficLightAnchorState
    extends State<MessagingTrafficLightAnchor> {
  Rect? _reported;

  void _report() {
    if (!mounted) {
      return;
    }
    final renderObject = context.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) {
      return;
    }
    final rect = renderObject.localToGlobal(Offset.zero) & renderObject.size;
    if (rect == _reported) {
      return;
    }
    _reported = rect;
    unawaited(ClientPlatformPorts.reportTrafficLightAnchor(rect));
  }

  void _scheduleReport() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _report());
  }

  @override
  void initState() {
    super.initState();
    _scheduleReport();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _scheduleReport();
  }

  @override
  Widget build(BuildContext context) {
    return ExcludeSemantics(
      child: LayoutBuilder(
        builder: (context, constraints) {
          _scheduleReport();
          return SizedBox(
            key: const Key('messaging-traffic-light-anchor'),
            width: widget.width,
            height: widget.height,
          );
        },
      ),
    );
  }
}
