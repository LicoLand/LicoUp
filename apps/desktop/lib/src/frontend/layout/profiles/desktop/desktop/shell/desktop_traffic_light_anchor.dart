import 'dart:async';

import 'package:flutter/widgets.dart';

import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/tokens/desktop_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/client_platform_ports.dart';

/// Reports its global rect to the macOS window chrome so the traffic lights
/// track this band (frozen window-chrome contract: `setTrafficLightAnchor`
/// takes window logical points, y down from the content top-left; null
/// restores the default 48pt top band).
///
/// The shell mounts exactly one reporter at a time: inside the settings
/// copy's left card when settings is active, at the main area's top-left
/// inset otherwise. Reports fire after mount and after every relayout; on
/// dispose the last reporter restores the default band.
final class DesktopTrafficLightAnchor extends StatefulWidget {
  const DesktopTrafficLightAnchor({
    super.key,
    this.width = 96,
    this.height = DesktopDesktopMetrics.trafficLightAnchorExtent,
  });

  final double width;
  final double height;

  @override
  State<DesktopTrafficLightAnchor> createState() =>
      _DesktopTrafficLightAnchorState();
}

final class _DesktopTrafficLightAnchorState
    extends State<DesktopTrafficLightAnchor> {
  static Object? _lastReporter;

  final GlobalKey _key = GlobalKey();
  Rect? _reported;

  @override
  void initState() {
    super.initState();
    _scheduleReport();
  }

  @override
  void didUpdateWidget(DesktopTrafficLightAnchor oldWidget) {
    super.didUpdateWidget(oldWidget);
    _scheduleReport();
  }

  @override
  void dispose() {
    if (identical(_lastReporter, this)) {
      _lastReporter = null;
      unawaited(ClientPlatformPorts.reportTrafficLightAnchor(null));
    }
    super.dispose();
  }

  void _scheduleReport() {
    WidgetsBinding.instance.addPostFrameCallback((_) => _report());
  }

  void _report() {
    if (!mounted) return;
    final renderObject = _key.currentContext?.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return;
    final rect = renderObject.localToGlobal(Offset.zero) & renderObject.size;
    if (_reported == rect) return;
    _reported = rect;
    _lastReporter = this;
    unawaited(ClientPlatformPorts.reportTrafficLightAnchor(rect));
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: _key,
      width: widget.width,
      height: widget.height,
      child: LayoutBuilder(
        builder: (context, constraints) {
          _scheduleReport();
          return const SizedBox.expand();
        },
      ),
    );
  }
}
