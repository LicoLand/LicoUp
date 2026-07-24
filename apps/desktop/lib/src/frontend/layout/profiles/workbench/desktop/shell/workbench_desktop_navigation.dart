import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';

const double _navIconButtonWidth = 40;
const double _navButtonHeight = 36;
const double _navIconSize = 22;
const double _navGap = 2;
const double _controlCornerRadius = 8;

final class WorkbenchDesktopNavigation extends StatelessWidget {
  const WorkbenchDesktopNavigation({
    super.key,
    required this.current,
    required this.onSelect,
  });

  final ClientSection current;
  final ValueChanged<ClientSection> onSelect;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final items = [
      (ClientSection.agents, strings.agents),
      (ClientSection.pluginManagement, strings.pluginManagement),
    ];
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final item in items) ...[
          _WorkbenchTopNavButton(
            selected: current == item.$1,
            section: item.$1,
            label: item.$2,
            onPressed: () => onSelect(item.$1),
          ),
          const SizedBox(width: _navGap),
        ],
      ],
    );
  }
}

final class _WorkbenchTopNavButton extends StatefulWidget {
  const _WorkbenchTopNavButton({
    required this.selected,
    required this.section,
    required this.label,
    required this.onPressed,
  });

  final bool selected;
  final ClientSection section;
  final String label;
  final VoidCallback onPressed;

  @override
  State<_WorkbenchTopNavButton> createState() => _WorkbenchTopNavButtonState();
}

final class _WorkbenchTopNavButtonState extends State<_WorkbenchTopNavButton> {
  bool _hovered = false;

  Key? get _iconKey => switch (widget.section) {
    ClientSection.agents => const Key('topbar-agents-icon'),
    _ => null,
  };

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    final isActive = widget.selected;
    final silver = colors.isDark ? Colors.white : colors.text;
    const neonYellow = Color(0xFFEFFF00);
    final iconColor = isActive
        ? neonYellow
        : _hovered
        ? silver.withAlpha(230)
        : silver.withAlpha(200);
    final icon = _WorkbenchSectionIcon(
      key: _iconKey,
      section: widget.section,
      color: iconColor,
      size: _navIconSize,
      glow: isActive,
    );

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        onTap: widget.onPressed,
        child: Tooltip(
          message: widget.label,
          waitDuration: const Duration(milliseconds: 400),
          child: AnimatedContainer(
            key: isActive
                ? Key('topbar-nav-active-${widget.section.name}')
                : null,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOutQuart,
            width: _navIconButtonWidth,
            height: _navButtonHeight,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(_controlCornerRadius),
              color: Colors.transparent,
            ),
            child: Center(child: icon),
          ),
        ),
      ),
    );
  }
}

final class _WorkbenchSectionIcon extends StatelessWidget {
  const _WorkbenchSectionIcon({
    super.key,
    required this.section,
    required this.color,
    required this.size,
    required this.glow,
  });

  final ClientSection section;
  final Color color;
  final double size;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    final child = section == ClientSection.agents
        ? _WorkbenchAgentRobotIcon(color: color, size: size)
        : Icon(_sectionIcon(section), color: color, size: size);
    if (!glow) {
      return child;
    }
    return Stack(
      alignment: Alignment.center,
      children: [
        ImageFiltered(
          imageFilter: ImageFilter.blur(sigmaX: 2.5, sigmaY: 2.5),
          child: Opacity(opacity: 0.6, child: child),
        ),
        child,
      ],
    );
  }
}

final class _WorkbenchAgentRobotIcon extends StatelessWidget {
  const _WorkbenchAgentRobotIcon({required this.color, required this.size});

  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size.square(size),
    painter: _WorkbenchAgentRobotIconPainter(color),
  );
}

final class _WorkbenchAgentRobotIconPainter extends CustomPainter {
  const _WorkbenchAgentRobotIconPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.shortestSide / 1024;
    canvas
      ..save()
      ..scale(scale);
    final paint = Paint()
      ..color = color
      ..isAntiAlias = true;
    final stroke = Paint()
      ..color = color
      ..isAntiAlias = true
      ..style = PaintingStyle.stroke
      ..strokeWidth = 63.15;
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(92, 285.35, 840, 582.15),
        const Radius.circular(68),
      ),
      stroke,
    );
    canvas.drawCircle(const Offset(323.93, 576.51), 68.27, paint);
    canvas.drawCircle(const Offset(699.9, 576.51), 68.27, paint);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        const Rect.fromLTWH(251.73, 127.49, 520.54, 63.15),
        const Radius.circular(31.57),
      ),
      paint,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _WorkbenchAgentRobotIconPainter oldDelegate) =>
      oldDelegate.color != color;
}

IconData _sectionIcon(ClientSection section) => switch (section) {
  ClientSection.agents => Icons.psychology_outlined,
  ClientSection.monitoring => Icons.query_stats_outlined,
  ClientSection.skillHub => Icons.library_books_outlined,
  ClientSection.pluginManagement => Icons.extension_outlined,
  ClientSection.mobileRelay => Icons.phonelink_outlined,
  ClientSection.settings => Icons.settings_outlined,
};
