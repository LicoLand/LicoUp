import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_port.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/profiles/bubble/desktop/chrome/bubble_desktop_glass.dart';

const double _railWidth = 64;
const double _railIconSize = 20;
const double _railHitSize = 36;
const double _railCapsulePad = 6;
const double _railItemGap = 4;
const double _railMacTrafficLightInset = 36;
const double _railTopContentGap = 40;
const double _sidebarSearchWidth = 320;

/// Bubble-owned narrow icon rail.
final class BubbleDesktopSidebarRail extends StatelessWidget {
  const BubbleDesktopSidebarRail({
    super.key,
    required this.chrome,
    required this.section,
    required this.onSelectSection,
  });

  final LayoutChromePort chrome;
  final ClientSection section;
  final ValueChanged<ClientSection> onSelectSection;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final isMacOS = Theme.of(context).platform == TargetPlatform.macOS;
    final items = _desktopNavItems(strings);

    return SizedBox(
      width: _railWidth,
      child: ColoredBox(
        color: context.layoutPalette.background,
        child: Padding(
          padding: EdgeInsets.only(
            top: (isMacOS ? _railMacTrafficLightInset : 8) + _railTopContentGap,
            bottom: 12,
          ),
          child: Column(
            children: [
              _RailCapsule(
                children: [
                  for (final item in items)
                    _RailCircleButton(
                      key: Key('sidebar-rail-nav-${item.$1.name}'),
                      selected: section == item.$1,
                      tooltip: item.$2,
                      icon: item.$1 == ClientSection.agents
                          ? Icons.psychology_outlined
                          : _sectionIcon(item.$1),
                      onPressed: () => onSelectSection(item.$1),
                    ),
                ],
              ),
              const Spacer(),
              _RailCircleButton(
                key: const Key('sidebar-rail-pairing-button'),
                selected: false,
                tooltip: strings.mobileRelay,
                icon: Icons.qr_code_2_rounded,
                onPressed: () => unawaited(chrome.openPairing(context)),
              ),
              const SizedBox(height: 10),
              _RailCapsule(
                children: [
                  _RailCircleButton(
                    key: const Key('sidebar-rail-settings-button'),
                    selected: section == ClientSection.settings,
                    tooltip: strings.settings,
                    icon: Icons.settings_outlined,
                    onPressed: () => onSelectSection(ClientSection.settings),
                  ),
                  _RailCircleButton(
                    key: const Key('sidebar-rail-avatar-button'),
                    selected: false,
                    tooltip: strings.settings,
                    icon: Icons.person_rounded,
                    onPressed: () => onSelectSection(ClientSection.settings),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Bubble-owned centered search top bar.
final class BubbleDesktopContentTopBar extends StatelessWidget {
  const BubbleDesktopContentTopBar({
    super.key,
    required this.section,
    required this.onSearchSelect,
  });

  final ClientSection section;
  final ValueChanged<ClientSection> onSearchSelect;

  @override
  Widget build(BuildContext context) {
    final palette = context.layoutPalette;
    return SizedBox(
      height: BubbleDesktopControlMetrics.topBarHeight,
      child: ColoredBox(
        color: palette.background,
        child: Center(
          child: _BubbleSidebarSearch(
            current: section,
            onSelect: onSearchSelect,
          ),
        ),
      ),
    );
  }
}

/// Bubble-owned status chrome driven by a semantic port.
final class BubbleDesktopStatusBar extends StatelessWidget {
  const BubbleDesktopStatusBar({super.key, required this.chrome});

  final LayoutChromePort chrome;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<LayoutChromeSnapshot>(
      valueListenable: chrome,
      builder: (context, snapshot, _) {
        if (snapshot.status.displayText.isEmpty) {
          return const SizedBox.shrink();
        }
        return _BubbleStatusSnapshotBar(snapshot: snapshot);
      },
    );
  }
}

final class _RailCapsule extends StatelessWidget {
  const _RailCapsule({required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final palette = context.layoutPalette;
    final radius = (_railHitSize / 2) + _railCapsulePad;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: palette.isDark
            ? palette.surface.withAlpha(160)
            : palette.surface.withAlpha(220),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: palette.line.withAlpha(90)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: _railCapsulePad,
          vertical: _railCapsulePad,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var index = 0; index < children.length; index++) ...[
              if (index > 0) const SizedBox(height: _railItemGap),
              children[index],
            ],
          ],
        ),
      ),
    );
  }
}

final class _RailCircleButton extends StatefulWidget {
  const _RailCircleButton({
    super.key,
    required this.selected,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
  });

  final bool selected;
  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  State<_RailCircleButton> createState() => _RailCircleButtonState();
}

final class _RailCircleButtonState extends State<_RailCircleButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final palette = context.layoutPalette;
    final iconColor = widget.selected
        ? (palette.isDark ? palette.background : Colors.white)
        : _hovered
        ? palette.text.withAlpha(230)
        : palette.text.withAlpha(200);
    final fill = widget.selected
        ? (palette.isDark ? palette.text : const Color(0xFF1A1A1A))
        : _hovered
        ? palette.surfaceLow.withAlpha(palette.isDark ? 180 : 220)
        : Colors.transparent;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Tooltip(
        message: widget.tooltip,
        waitDuration: const Duration(milliseconds: 400),
        child: InkWell(
          onTap: widget.onPressed,
          customBorder: const CircleBorder(),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 160),
            width: _railHitSize,
            height: _railHitSize,
            decoration: BoxDecoration(shape: BoxShape.circle, color: fill),
            child: Icon(widget.icon, size: _railIconSize, color: iconColor),
          ),
        ),
      ),
    );
  }
}

final class _BubbleSidebarSearch extends StatefulWidget {
  const _BubbleSidebarSearch({required this.current, required this.onSelect});

  final ClientSection current;
  final ValueChanged<ClientSection> onSelect;

  @override
  State<_BubbleSidebarSearch> createState() => _BubbleSidebarSearchState();
}

final class _BubbleSidebarSearchState extends State<_BubbleSidebarSearch> {
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

  List<_SearchItem> _items(LicoStrings strings) {
    return [
      for (final section in ClientSection.values)
        _SearchItem(
          section: section,
          label: _sectionTitle(strings, section),
          aliases: _sectionSearchAliases(section),
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final palette = context.layoutPalette;
    final strings = LicoStrings.of(context);
    final items = _items(strings);
    const fieldHeight = 32.0;
    final pillRadius = fieldHeight / 2;
    final idleBorder = palette.line.withAlpha(palette.isDark ? 70 : 90);
    final focusBorder = palette.primaryStrong.withAlpha(200);

    return Focus(
      onKeyEvent: _handleKeyEvent,
      child: SizedBox(
        key: const Key('shell-sidebar-search'),
        width: _sidebarSearchWidth,
        height: fieldHeight,
        child: Autocomplete<_SearchItem>(
          displayStringForOption: (item) => item.label,
          optionsBuilder: (value) {
            final query = value.text.trim();
            if (query.isEmpty) {
              return const Iterable<_SearchItem>.empty();
            }
            return items.where((item) => item.matches(query));
          },
          onSelected: (item) => widget.onSelect(item.section),
          fieldViewBuilder:
              (context, textController, focusNode, onFieldSubmitted) {
                _bindFocus(focusNode);
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 140),
                  curve: Curves.easeOut,
                  height: fieldHeight,
                  width: _sidebarSearchWidth,
                  alignment: Alignment.centerLeft,
                  decoration: BoxDecoration(
                    color: palette.isDark
                        ? palette.surface.withAlpha(180)
                        : palette.surface.withAlpha(220),
                    borderRadius: BorderRadius.circular(pillRadius),
                    border: Border.all(
                      color: _focused ? focusBorder : idleBorder,
                      width: _focused ? 1.5 : 1,
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    child: Row(
                      children: [
                        Icon(
                          Icons.search_rounded,
                          size: 15,
                          color: palette.textMuted,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: textController,
                            focusNode: focusNode,
                            cursorColor: palette.primaryStrong,
                            textAlign: TextAlign.start,
                            textAlignVertical: TextAlignVertical.center,
                            style: TextStyle(
                              color: palette.text,
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
                              hintText: strings.sidebarSearchHint,
                              hintStyle: TextStyle(
                                color: palette.textMuted,
                                fontSize: 13,
                                fontWeight: FontWeight.w400,
                                height: 1,
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
                      ],
                    ),
                  ),
                );
              },
          optionsViewBuilder: (context, onSelected, options) {
            return Align(
              alignment: Alignment.topCenter,
              child: Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Material(
                  elevation: 8,
                  color: palette.surfaceLow,
                  borderRadius: BorderRadius.circular(14),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: _sidebarSearchWidth,
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
                                ? palette.primaryStrong
                                : palette.textMuted,
                          ),
                          title: Text(
                            item.label,
                            style: TextStyle(
                              color: palette.text,
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

final class _SearchItem {
  const _SearchItem({
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

final class _BubbleStatusSnapshotBar extends StatelessWidget {
  const _BubbleStatusSnapshotBar({required this.snapshot});

  final LayoutChromeSnapshot snapshot;

  @override
  Widget build(BuildContext context) {
    final palette = context.layoutPalette;
    final statusText = snapshot.status.displayText;
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: palette.background,
        border: Border(top: BorderSide(color: palette.line.withAlpha(50))),
      ),
      child: Row(
        children: [
          Container(
            width: 5,
            height: 5,
            margin: const EdgeInsets.only(right: 8),
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: palette.success.withAlpha(180),
            ),
          ),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              switchInCurve: Curves.easeOutQuart,
              switchOutCurve: Curves.easeInQuart,
              layoutBuilder: (currentChild, previousChildren) {
                return Stack(
                  alignment: Alignment.centerLeft,
                  children: <Widget>[...previousChildren, ?currentChild],
                );
              },
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
                  color: palette.textMuted,
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

List<(ClientSection, String)> _desktopNavItems(LicoStrings strings) => [
  (ClientSection.agents, strings.agents),
  (ClientSection.pluginManagement, strings.pluginManagement),
];

String _sectionTitle(LicoStrings strings, ClientSection section) {
  return switch (section) {
    ClientSection.agents => strings.agents,
    ClientSection.monitoring => strings.tokenUsage,
    ClientSection.skillHub => strings.skillHub,
    ClientSection.pluginManagement => strings.pluginManagement,
    ClientSection.mobileRelay => strings.mobileRelay,
    ClientSection.settings => strings.settings,
  };
}

IconData _sectionIcon(ClientSection section) {
  return switch (section) {
    ClientSection.agents => Icons.psychology_outlined,
    ClientSection.monitoring => Icons.query_stats_outlined,
    ClientSection.skillHub => Icons.library_books_outlined,
    ClientSection.pluginManagement => Icons.extension_outlined,
    ClientSection.mobileRelay => Icons.phonelink_outlined,
    ClientSection.settings => Icons.settings_outlined,
  };
}

List<String> _sectionSearchAliases(ClientSection section) {
  return switch (section) {
    ClientSection.agents => ['agent', 'chat', '智能体', '对话'],
    ClientSection.monitoring => [
      'token',
      'usage',
      'chart',
      'monitoring',
      '用量',
      '统计',
      '图表',
    ],
    ClientSection.skillHub => ['skill', 'hub', '技能'],
    ClientSection.pluginManagement => ['plugin', 'adapter', '插件', '适配器'],
    ClientSection.mobileRelay => ['mobile', 'relay', 'pair', '配对'],
    ClientSection.settings => ['setting', 'preference', '设置'],
  };
}
