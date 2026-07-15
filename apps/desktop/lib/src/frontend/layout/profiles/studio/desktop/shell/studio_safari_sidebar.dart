import 'dart:async';

import 'package:flutter/material.dart';

import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/layout/layout_chrome_port.dart';
import 'package:flutter_client/src/frontend/layout/layout_palette.dart';
import 'package:flutter_client/src/frontend/layout/profiles/studio/desktop/shell/studio_desktop_navigation.dart';

const double studioSafariSidebarWidth = 220;
const double studioSafariSidebarMinWidth = 168;
const double studioSafariSidebarMaxWidth = 320;
const double studioSafariSidebarCollapsedWidth = 118;
const double _cardInset = 10;
const double _cardRadius = 14;
const double _macTrafficLightInset = 36;
const double _rowHeight = 36;
const double _resizeHandleWidth = 8;
const double _collapseHitSize = 28;

final class StudioSafariSidebar extends StatelessWidget {
  const StudioSafariSidebar({
    super.key,
    required this.chrome,
    required this.section,
    required this.onSelectSection,
    required this.width,
    required this.onWidthDelta,
    required this.collapsed,
    required this.onToggleCollapsed,
  });

  final LayoutChromePort chrome;
  final ClientSection section;
  final double width;
  final ValueChanged<double> onWidthDelta;
  final bool collapsed;
  final VoidCallback onToggleCollapsed;
  final ValueChanged<ClientSection> onSelectSection;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final colors = context.layoutPalette;
    final isMacOS = Theme.of(context).platform == TargetPlatform.macOS;
    final items = studioDesktopNavigationItems(strings);
    final topInset = isMacOS ? _macTrafficLightInset : 10.0;
    final cardDecoration = BoxDecoration(
      color: colors.isDark
          ? Color.lerp(colors.surface, Colors.white, 0.04)!.withAlpha(210)
          : colors.surface.withAlpha(240),
      borderRadius: BorderRadius.circular(_cardRadius),
      border: Border.all(color: colors.line.withAlpha(70)),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withAlpha(colors.isDark ? 90 : 28),
          blurRadius: 24,
          offset: const Offset(0, 8),
        ),
      ],
    );
    final toggle = Positioned(
      top: 4,
      right: 4,
      child: _StudioSafariSidebarCollapseButton(
        key: Key(
          collapsed ? 'safari-sidebar-expand' : 'safari-sidebar-collapse',
        ),
        tooltip: collapsed
            ? strings.expandAgentsSidebar
            : strings.collapseAgentsSidebar,
        onPressed: onToggleCollapsed,
      ),
    );

    if (collapsed) {
      return SizedBox(
        width: studioSafariSidebarCollapsedWidth,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(_cardInset, _cardInset, 0, 0),
          child: SizedBox(
            height: topInset + _collapseHitSize,
            child: DecoratedBox(
              key: const Key('safari-sidebar-card'),
              decoration: cardDecoration,
              child: Stack(children: [toggle]),
            ),
          ),
        ),
      );
    }

    return SizedBox(
      width: width,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          _cardInset,
          _cardInset,
          0,
          _cardInset,
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: DecoratedBox(
                key: const Key('safari-sidebar-card'),
                decoration: cardDecoration,
                child: Padding(
                  padding: EdgeInsets.fromLTRB(8, topInset, 8, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final item in items)
                        _StudioSafariNavRow(
                          key: Key('safari-sidebar-nav-${item.$1.name}'),
                          selected: section == item.$1,
                          label: item.$2,
                          icon: item.$1 == ClientSection.agents
                              ? Icons.psychology_outlined
                              : studioDesktopSectionIcon(item.$1),
                          onPressed: () => onSelectSection(item.$1),
                        ),
                      const Spacer(),
                      _StudioSafariNavRow(
                        key: const Key('safari-sidebar-pairing-button'),
                        selected: false,
                        label: strings.mobileRelay,
                        icon: Icons.qr_code_2_rounded,
                        onPressed: () {
                          unawaited(chrome.openPairing(context));
                        },
                      ),
                      const SizedBox(height: 4),
                      _StudioSafariNavRow(
                        key: const Key('safari-sidebar-settings-button'),
                        selected: section == ClientSection.settings,
                        label: strings.settings,
                        icon: Icons.settings_outlined,
                        onPressed: () =>
                            onSelectSection(ClientSection.settings),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            toggle,
            Positioned(
              top: 0,
              bottom: 0,
              right: 0,
              width: _resizeHandleWidth,
              child: MouseRegion(
                cursor: SystemMouseCursors.resizeLeftRight,
                child: GestureDetector(
                  key: const Key('safari-sidebar-resize-handle'),
                  behavior: HitTestBehavior.opaque,
                  onHorizontalDragUpdate: (details) {
                    onWidthDelta(details.delta.dx);
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _StudioSafariSidebarCollapseButton extends StatefulWidget {
  const _StudioSafariSidebarCollapseButton({
    super.key,
    required this.tooltip,
    required this.onPressed,
  });

  final String tooltip;
  final VoidCallback onPressed;

  @override
  State<_StudioSafariSidebarCollapseButton> createState() =>
      _StudioSafariSidebarCollapseButtonState();
}

final class _StudioSafariSidebarCollapseButtonState
    extends State<_StudioSafariSidebarCollapseButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    final iconColor = colors.text.withAlpha(_hovered ? 245 : 210);
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onPressed,
          child: SizedBox(
            width: _collapseHitSize,
            height: _collapseHitSize,
            child: Center(
              child: CustomPaint(
                size: const Size(18, 16),
                painter: _StudioSafariSidebarToggleGlyphPainter(
                  color: iconColor,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _StudioSafariSidebarToggleGlyphPainter extends CustomPainter {
  const _StudioSafariSidebarToggleGlyphPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    final outer = RRect.fromRectAndRadius(
      Rect.fromLTWH(0.5, 0.5, size.width - 1, size.height - 1),
      const Radius.circular(3),
    );
    canvas.drawRRect(outer, stroke);

    final railRight = size.width * 0.38;
    canvas.drawLine(
      Offset(railRight, 1.5),
      Offset(railRight, size.height - 1.5),
      stroke,
    );

    final lineLeft = 3.2;
    final lineRight = railRight - 2.4;
    const lineYs = <double>[4.2, 8.0, 11.8];
    for (final y in lineYs) {
      canvas.drawLine(Offset(lineLeft, y), Offset(lineRight, y), stroke);
    }
  }

  @override
  bool shouldRepaint(_StudioSafariSidebarToggleGlyphPainter oldDelegate) =>
      oldDelegate.color != color;
}

final class _StudioSafariNavRow extends StatefulWidget {
  const _StudioSafariNavRow({
    super.key,
    required this.selected,
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final bool selected;
  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  State<_StudioSafariNavRow> createState() => _StudioSafariNavRowState();
}

final class _StudioSafariNavRowState extends State<_StudioSafariNavRow> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    final selected = widget.selected;
    final highlight = selected || _hovered;
    return Tooltip(
      message: widget.label,
      waitDuration: const Duration(milliseconds: 500),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onPressed,
            borderRadius: BorderRadius.circular(8),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              height: _rowHeight,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: selected
                    ? colors.primary.withAlpha(colors.isDark ? 48 : 36)
                    : highlight
                    ? colors.surfaceLow.withAlpha(180)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(
                    widget.icon,
                    size: 17,
                    color: selected
                        ? colors.primaryStrong
                        : colors.text.withAlpha(210),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: selected
                            ? FontWeight.w600
                            : FontWeight.w500,
                        color: selected
                            ? colors.text
                            : colors.text.withAlpha(220),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
