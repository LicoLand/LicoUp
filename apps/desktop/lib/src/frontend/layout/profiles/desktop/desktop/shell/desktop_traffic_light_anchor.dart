import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/widgets.dart';

import 'package:licoup/src/frontend/layout/profiles/desktop/desktop/tokens/desktop_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/client_platform_ports.dart';

/// Reports its global rect to the macOS window chrome so the traffic lights
/// track this band (window-chrome contract: `setTrafficLightAnchor` takes
/// window logical points, y down from the content top-left; null restores
/// the default 48pt top band).
///
/// The band is the title row's leading region: it starts at the pane's left
/// edge and spans the full title-row height so the lights sit vertically
/// centred. The host replies with the trailing edge of the light cluster in
/// the same coordinates; once it arrives the anchor widens to
/// `trailingEdge - rect.left + [gapAfter]` so the app icon never slides
/// under the lights — on macOS 26 the cluster is wider than any fixed band.
/// Until the first reply the anchor holds [fallbackWidth].
///
/// The shell mounts exactly one reporter, in the work-area title row. Reports
/// fire after mount and after every relayout; on dispose the last reporter
/// restores the default band.
final class DesktopTrafficLightAnchor extends StatefulWidget {
  const DesktopTrafficLightAnchor({
    super.key,
    this.height = DesktopDesktopMetrics.titleRowExtent,
  });

  /// Band width before the host replies with the light cluster's trailing
  /// edge.
  static const double fallbackWidth = 92;

  /// Gap between the cluster's trailing edge and the title content.
  static const double gapAfter = 16;

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
  double? _resolvedWidth;

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
    final bounds = renderObject.localToGlobal(Offset.zero) & renderObject.size;
    // The band is the title row's leading region. The row's bottom hairline
    // insets this widget by half a pixel, so the reported rect keeps the
    // declared band height anchored at the rendered top.
    final rect = Rect.fromLTWH(
      bounds.left,
      bounds.top,
      bounds.width,
      widget.height,
    );
    if (_reported == rect) return;
    _reported = rect;
    _lastReporter = this;
    unawaited(_reportAndResize(rect));
  }

  Future<void> _reportAndResize(Rect rect) async {
    final edges = await ClientPlatformPorts.reportTrafficLightAnchor(rect);
    if (!mounted || edges == null) return;
    final trailing = edges.trailing;
    if (!identical(_lastReporter, this)) return;
    final base = _reported;
    if (base == null) return;
    final width =
        math.max(0.0, trailing - base.left) +
        DesktopTrafficLightAnchor.gapAfter;
    if (_resolvedWidth == null || (width - _resolvedWidth!).abs() > 0.5) {
      setState(() => _resolvedWidth = width);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      key: _key,
      width: _resolvedWidth ?? DesktopTrafficLightAnchor.fallbackWidth,
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
