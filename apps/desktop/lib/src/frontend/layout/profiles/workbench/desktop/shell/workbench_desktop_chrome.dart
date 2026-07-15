import 'dart:async';
import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/layout/layout_chrome_port.dart';
import 'package:flutter_client/src/frontend/layout/layout_palette.dart';
import 'package:flutter_client/src/frontend/layout/profiles/workbench/desktop/presentation/workbench_chrome_allowance_presentation.dart';

/// Workbench-private copy of the frozen desktop chrome.
///
/// These measurements deliberately remain local to this renderer so another
/// profile can change its chrome without changing Workbench.
abstract final class WorkbenchDesktopChromeMetrics {
  static const double searchFieldHeight = 28;
  static const double searchButtonSize = 32;
  static const double searchButtonEdgeInset = 8;
  static const double menuCornerRadius = 10;
  static const double searchCornerRadius = menuCornerRadius;
  static const double controlCornerRadius = 8;

  static double get searchButtonRadius => searchButtonSize / 2;

  static double get windowCornerRadius =>
      searchButtonRadius + searchButtonEdgeInset;

  static double get topBarHeight =>
      searchButtonSize + (searchButtonEdgeInset * 2);

  static BorderRadius get windowBorderRadius =>
      BorderRadius.circular(windowCornerRadius);
}

const double _topBarTrafficLightInset = 96;
const double _topBarNavIconButtonWidth = 40;
const double _topBarNavButtonHeight = 36;
const double _topBarIconSize = 22;
const double _topBarNavGap = 2;
const double _topBarTrailingInset = 10;
const double _topBarTrailingHitSize = 32;

final class WorkbenchDesktopTopBar extends StatelessWidget {
  const WorkbenchDesktopTopBar({
    super.key,
    required this.chrome,
    required this.section,
    required this.onSearchSelect,
    required this.onSelectSection,
  });

  final LayoutChromePort chrome;
  final ClientSection section;
  final ValueChanged<ClientSection> onSearchSelect;
  final ValueChanged<ClientSection> onSelectSection;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    final isMacOS = Theme.of(context).platform == TargetPlatform.macOS;

    return SizedBox(
      height: WorkbenchDesktopChromeMetrics.topBarHeight,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: colors.background,
          border: Border(bottom: BorderSide(color: colors.line.withAlpha(60))),
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: Center(
                child: _WorkbenchCenterSearch(
                  width: 240,
                  current: section,
                  onSelect: onSearchSelect,
                ),
              ),
            ),
            Positioned(
              left: isMacOS ? _topBarTrafficLightInset : 12,
              top: 0,
              bottom: 0,
              child: Align(
                alignment: Alignment.centerLeft,
                child: _WorkbenchTopNav(
                  current: section,
                  onSelect: onSelectSection,
                ),
              ),
            ),
            Positioned(
              right: _topBarTrailingInset,
              top: 0,
              bottom: 0,
              child: Align(
                alignment: Alignment.centerRight,
                child: _WorkbenchTrailingTools(
                  chrome: chrome,
                  onSelectSection: onSelectSection,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

final class _WorkbenchTopNav extends StatelessWidget {
  const _WorkbenchTopNav({required this.current, required this.onSelect});

  final ClientSection current;
  final ValueChanged<ClientSection> onSelect;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    final strings = LicoStrings.of(context);
    final items = [
      (ClientSection.controlPanel, strings.controlPanel),
      (ClientSection.agents, strings.agents),
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
          if (item.$1 == ClientSection.controlPanel)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: SizedBox(
                height: 16,
                child: VerticalDivider(
                  key: const Key('topbar-control-panel-divider'),
                  width: 1,
                  thickness: 1,
                  color: colors.line.withAlpha(100),
                ),
              ),
            )
          else
            const SizedBox(width: _topBarNavGap),
        ],
      ],
    );
  }
}

final class _WorkbenchTrailingTools extends StatelessWidget {
  const _WorkbenchTrailingTools({
    required this.chrome,
    required this.onSelectSection,
  });

  final LayoutChromePort chrome;
  final ValueChanged<ClientSection> onSelectSection;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    final strings = LicoStrings.of(context);
    final iconColor = colors.text.withAlpha(210);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _WorkbenchTrailingIconButton(
          key: const Key('topbar-pairing-button'),
          tooltip: strings.mobileRelay,
          icon: Icons.qr_code_2_rounded,
          color: iconColor,
          onPressed: () => unawaited(chrome.openPairing(context)),
        ),
        const SizedBox(width: 2),
        _WorkbenchTrailingIconButton(
          key: const Key('topbar-settings-button'),
          tooltip: strings.settings,
          icon: Icons.settings_outlined,
          color: iconColor,
          onPressed: () => onSelectSection(ClientSection.settings),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: SizedBox(
            height: 16,
            child: VerticalDivider(
              key: const Key('topbar-trailing-divider'),
              width: 1,
              thickness: 1,
              color: colors.line.withAlpha(120),
            ),
          ),
        ),
        Tooltip(
          message: strings.settings,
          waitDuration: const Duration(milliseconds: 400),
          child: InkWell(
            key: const Key('topbar-avatar-button'),
            customBorder: const CircleBorder(),
            onTap: () => onSelectSection(ClientSection.settings),
            child: Container(
              width: _topBarTrailingHitSize,
              height: _topBarTrailingHitSize,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: colors.surfaceLow,
                border: Border.all(color: colors.line.withAlpha(120)),
              ),
              child: Icon(
                Icons.person_rounded,
                size: _topBarIconSize,
                color: colors.textMuted,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

final class _WorkbenchTrailingIconButton extends StatelessWidget {
  const _WorkbenchTrailingIconButton({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.color,
    required this.onPressed,
  });

  final String tooltip;
  final IconData icon;
  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        child: SizedBox.square(
          dimension: _topBarTrailingHitSize,
          child: Icon(icon, size: _topBarIconSize, color: color),
        ),
      ),
    );
  }
}

final class _WorkbenchCenterSearch extends StatefulWidget {
  const _WorkbenchCenterSearch({
    required this.current,
    required this.onSelect,
    required this.width,
  });

  final ClientSection current;
  final ValueChanged<ClientSection> onSelect;
  final double width;

  @override
  State<_WorkbenchCenterSearch> createState() => _WorkbenchCenterSearchState();
}

final class _WorkbenchCenterSearchState extends State<_WorkbenchCenterSearch> {
  bool _focused = false;
  FocusNode? _boundFocus;

  void _bindFocus(FocusNode focusNode) {
    if (identical(_boundFocus, focusNode)) {
      return;
    }
    _boundFocus?.removeListener(_onFocusChanged);
    _boundFocus = focusNode;
    _boundFocus!.addListener(_onFocusChanged);
  }

  void _onFocusChanged() {
    final focused = _boundFocus?.hasFocus ?? false;
    if (focused == _focused || !mounted) {
      return;
    }
    setState(() => _focused = focused);
  }

  @override
  void dispose() {
    _boundFocus?.removeListener(_onFocusChanged);
    super.dispose();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      node.unfocus();
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    final strings = LicoStrings.of(context);
    final items = [
      for (final section in ClientSection.values)
        if (section != ClientSection.skillHub &&
            section != ClientSection.localRuntime &&
            section != ClientSection.mobileRelay)
          _WorkbenchSearchItem(
            section: section,
            label: _sectionTitle(strings, section),
            aliases: _sectionSearchAliases(section),
          ),
    ];
    final radius = WorkbenchDesktopChromeMetrics.searchCornerRadius;
    final borderColor = _focused
        ? colors.primaryStrong.withAlpha(200)
        : colors.line.withAlpha(colors.isDark ? 90 : 120);

    return Focus(
      onKeyEvent: _handleKeyEvent,
      child: SizedBox(
        key: const Key('shell-global-search'),
        width: widget.width,
        height: WorkbenchDesktopChromeMetrics.searchFieldHeight + 8,
        child: Autocomplete<_WorkbenchSearchItem>(
          displayStringForOption: (item) => item.label,
          optionsBuilder: (value) {
            final query = value.text.trim();
            if (query.isEmpty) {
              return const Iterable<_WorkbenchSearchItem>.empty();
            }
            return items.where((item) => item.matches(query));
          },
          onSelected: (item) => widget.onSelect(item.section),
          fieldViewBuilder:
              (context, textController, focusNode, onFieldSubmitted) {
                _bindFocus(focusNode);
                final fieldHeight =
                    WorkbenchDesktopChromeMetrics.searchFieldHeight + 8.0;
                final horizontalInset = fieldHeight * 0.28;
                final iconGap = fieldHeight * 0.18;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 140),
                  curve: Curves.easeOut,
                  height: fieldHeight,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: colors.surfaceLow,
                    borderRadius: BorderRadius.circular(radius),
                    border: Border.all(
                      color: borderColor,
                      width: _focused ? 1.5 : 1,
                    ),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      SizedBox(width: horizontalInset),
                      Icon(
                        Icons.search_rounded,
                        size: 16,
                        color: colors.textMuted,
                      ),
                      SizedBox(width: iconGap),
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: TextField(
                            controller: textController,
                            focusNode: focusNode,
                            cursorColor: colors.primaryStrong,
                            textAlignVertical: TextAlignVertical.center,
                            style: TextStyle(
                              color: colors.text,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              height: 1,
                              leadingDistribution: TextLeadingDistribution.even,
                            ),
                            decoration: InputDecoration(
                              isDense: true,
                              isCollapsed: true,
                              filled: false,
                              border: InputBorder.none,
                              enabledBorder: InputBorder.none,
                              focusedBorder: InputBorder.none,
                              contentPadding: EdgeInsets.zero,
                              hintText: strings.globalSearchHint,
                              hintStyle: TextStyle(
                                color: colors.textMuted,
                                fontSize: 13,
                                fontWeight: FontWeight.w400,
                                height: 1,
                                leadingDistribution:
                                    TextLeadingDistribution.even,
                              ),
                            ),
                            onSubmitted: (raw) {
                              final query = raw.trim();
                              for (final item in items) {
                                if (item.matches(query)) {
                                  widget.onSelect(item.section);
                                  textController.clear();
                                  focusNode.unfocus();
                                  return;
                                }
                              }
                            },
                          ),
                        ),
                      ),
                      SizedBox(width: horizontalInset),
                    ],
                  ),
                );
              },
          optionsViewBuilder: (context, onSelected, options) {
            return Align(
              alignment: Alignment.topLeft,
              child: Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Material(
                  elevation: 8,
                  color: colors.surfaceLow,
                  borderRadius: BorderRadius.circular(radius),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: widget.width,
                      maxHeight: 280,
                    ),
                    child: ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      shrinkWrap: true,
                      itemCount: options.length,
                      itemBuilder: (context, index) {
                        final item = options.elementAt(index);
                        final selected = item.section == widget.current;
                        return ListTile(
                          dense: true,
                          leading: Icon(
                            _sectionIcon(item.section),
                            size: 16,
                            color: selected
                                ? colors.primaryStrong
                                : colors.textMuted,
                          ),
                          title: Text(
                            item.label,
                            style: TextStyle(
                              color: colors.text,
                              fontSize: 13,
                              fontWeight: selected
                                  ? FontWeight.w600
                                  : FontWeight.w500,
                            ),
                          ),
                          onTap: () {
                            onSelected(item);
                            widget.onSelect(item.section);
                          },
                        );
                      },
                    ),
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}

final class _WorkbenchSearchItem {
  const _WorkbenchSearchItem({
    required this.section,
    required this.label,
    required this.aliases,
  });

  final ClientSection section;
  final String label;
  final List<String> aliases;

  bool matches(String query) {
    final normalized = query.toLowerCase();
    return [
      label,
      section.name,
      ...aliases,
    ].any((value) => value.toLowerCase().startsWith(normalized));
  }
}

final class WorkbenchDesktopStatusBar extends StatelessWidget {
  const WorkbenchDesktopStatusBar({super.key, required this.chrome});

  final LayoutChromePort chrome;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<LayoutChromeSnapshot>(
      valueListenable: chrome,
      builder: (context, snapshot, child) {
        final statusText = snapshot.status.displayText;
        if (statusText.isEmpty && snapshot.allowance == null) {
          return const SizedBox.shrink();
        }
        final colors = context.layoutPalette;
        final allowance = presentLayoutChromeAllowance(
          snapshot.allowance,
          LicoStrings.of(context),
        );
        return Container(
          height: 30,
          padding: const EdgeInsets.symmetric(horizontal: 14),
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(
            color: colors.background,
            border: Border(top: BorderSide(color: colors.line.withAlpha(50))),
          ),
          child: Row(
            children: [
              Container(
                width: 5,
                height: 5,
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: colors.success.withAlpha(180),
                ),
              ),
              Expanded(
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  switchInCurve: Curves.easeOutQuart,
                  switchOutCurve: Curves.easeInQuart,
                  layoutBuilder: (currentChild, previousChildren) => Stack(
                    alignment: Alignment.centerLeft,
                    children: <Widget>[...previousChildren, ?currentChild],
                  ),
                  transitionBuilder: (child, animation) {
                    final offset = Tween<Offset>(
                      begin: const Offset(0, 0.6),
                      end: Offset.zero,
                    ).animate(animation);
                    return FadeTransition(
                      opacity: animation,
                      child: SlideTransition(position: offset, child: child),
                    );
                  },
                  child: Text(
                    statusText,
                    key: ValueKey('shell-status-text:$statusText'),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.left,
                    style: TextStyle(
                      color: colors.textMuted,
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              ),
              if (allowance != null) ...[
                const SizedBox(width: 12),
                _WorkbenchAllowanceGroup(presentation: allowance),
              ],
            ],
          ),
        );
      },
    );
  }
}

final class _WorkbenchAllowanceGroup extends StatelessWidget {
  const _WorkbenchAllowanceGroup({required this.presentation});

  final LayoutChromeAllowancePresentation presentation;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: presentation.tooltip,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var index = 0; index < presentation.meters.length; index++) ...[
            if (index > 0) const SizedBox(width: 10),
            _WorkbenchAllowanceMeter(
              key: Key(
                'agent-allowance-meter-${presentation.meters[index].semanticId}',
              ),
              meter: presentation.meters[index],
            ),
          ],
        ],
      ),
    );
  }
}

final class _WorkbenchAllowanceMeter extends StatelessWidget {
  const _WorkbenchAllowanceMeter({super.key, required this.meter});

  final LayoutChromeAllowanceMeterPresentation meter;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    final normalizedProgress = meter.progress?.clamp(0.0, 1.0);
    return SizedBox(
      height: 20,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(
            meter.label,
            maxLines: 1,
            style: TextStyle(
              color: colors.textMuted,
              fontWeight: FontWeight.w800,
              fontSize: 10,
            ),
          ),
          const SizedBox(width: 6),
          if (meter.showProgress) ...[
            SizedBox(
              width: 54,
              child: _WorkbenchAllowanceProgressTrack(
                key: Key('agent-allowance-progress-track-${meter.label}'),
                progress: normalizedProgress,
                fillColor: _toneColor(
                  meter.progressTone,
                  colors,
                  primaryMuted: true,
                ),
              ),
            ),
            const SizedBox(width: 6),
          ],
          Text(
            meter.valueText,
            key: Key('agent-allowance-meter-value-${meter.label}'),
            maxLines: 1,
            textAlign: TextAlign.right,
            style: TextStyle(
              color: _allowanceValueColor(meter.status, colors),
              fontWeight: FontWeight.w700,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

final class _WorkbenchAllowanceProgressTrack extends StatelessWidget {
  const _WorkbenchAllowanceProgressTrack({
    super.key,
    required this.progress,
    required this.fillColor,
  });

  final double? progress;
  final Color fillColor;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    final normalizedProgress = progress?.clamp(0.0, 1.0) ?? 0;
    return SizedBox(
      height: 7,
      child: Stack(
        fit: StackFit.expand,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(
              color: colors.surfaceHigh,
              borderRadius: BorderRadius.circular(999),
            ),
          ),
          if (normalizedProgress > 0)
            FractionallySizedBox(
              widthFactor: normalizedProgress,
              alignment: Alignment.centerLeft,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: fillColor,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
        ],
      ),
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
    ClientSection.controlPanel => const Key('topbar-control-panel-icon'),
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
      size: _topBarIconSize,
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
            width: _topBarNavIconButtonWidth,
            height: _topBarNavButtonHeight,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(
                WorkbenchDesktopChromeMetrics.controlCornerRadius,
              ),
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

String _sectionTitle(LicoStrings strings, ClientSection section) =>
    switch (section) {
      ClientSection.controlPanel => strings.controlPanel,
      ClientSection.agents => strings.agents,
      ClientSection.feed => strings.feed,
      ClientSection.monitoring => strings.tokenUsage,
      ClientSection.mcpPlugins => strings.extensionsHub,
      ClientSection.skillHub => strings.skillHub,
      ClientSection.localRuntime => strings.runtime,
      ClientSection.mobileRelay => strings.mobileRelay,
      ClientSection.settings => strings.settings,
    };

IconData _sectionIcon(ClientSection section) => switch (section) {
  ClientSection.controlPanel => Icons.dashboard_outlined,
  ClientSection.agents => Icons.psychology_outlined,
  ClientSection.feed => Icons.dynamic_feed_outlined,
  ClientSection.monitoring => Icons.query_stats_outlined,
  ClientSection.mcpPlugins => Icons.extension_outlined,
  ClientSection.skillHub => Icons.library_books_outlined,
  ClientSection.localRuntime => Icons.dns_outlined,
  ClientSection.mobileRelay => Icons.phonelink_outlined,
  ClientSection.settings => Icons.settings_outlined,
};

List<String> _sectionSearchAliases(ClientSection section) => switch (section) {
  ClientSection.controlPanel => [
    'control',
    'panel',
    'dashboard',
    'home',
    'feed',
    'timeline',
    '控制面板',
    '动态',
    '主页',
    '广场',
  ],
  ClientSection.agents => ['agent', 'chat', '智能体', '对话'],
  ClientSection.feed => ['feed', 'timeline', '广场', '动态'],
  ClientSection.monitoring => [
    'token',
    'usage',
    'chart',
    'monitoring',
    '用量',
    '统计',
    '图表',
  ],
  ClientSection.mcpPlugins => [
    'mcp',
    'plugin',
    '插件',
    'skill',
    'hub',
    '技能',
    'extensions',
    '扩展',
  ],
  ClientSection.skillHub => ['skill', 'hub', '技能'],
  ClientSection.localRuntime => ['runtime', 'server', '运行时'],
  ClientSection.mobileRelay => ['mobile', 'relay', 'pair', '配对'],
  ClientSection.settings => ['setting', 'preference', '设置'],
};

Color _allowanceValueColor(String status, LayoutPalette colors) =>
    switch (status.trim().toLowerCase()) {
      'exhausted' => colors.error,
      'not-configured' => colors.warning,
      'unavailable' => colors.textMuted,
      _ => colors.text,
    };

Color _toneColor(
  LayoutChromeStatusTone tone,
  LayoutPalette colors, {
  required bool primaryMuted,
}) => switch (tone) {
  LayoutChromeStatusTone.neutral => colors.textMuted,
  LayoutChromeStatusTone.primaryMuted =>
    primaryMuted ? colors.primary.withAlpha(120) : colors.primary,
  LayoutChromeStatusTone.info => colors.info,
  LayoutChromeStatusTone.success => colors.success,
  LayoutChromeStatusTone.warning => colors.warning,
  LayoutChromeStatusTone.error => colors.error,
};
