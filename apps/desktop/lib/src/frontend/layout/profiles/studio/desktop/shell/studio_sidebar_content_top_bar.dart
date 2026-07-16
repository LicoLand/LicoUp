import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/layout/layout_palette.dart';
import 'package:flutter_client/src/frontend/layout/profiles/studio/desktop/shell/studio_desktop_chrome_metrics.dart';
import 'package:flutter_client/src/frontend/layout/profiles/studio/desktop/shell/studio_desktop_navigation.dart';

final class StudioSidebarContentTopBar extends StatelessWidget {
  const StudioSidebarContentTopBar({
    super.key,
    required this.section,
    required this.onSearchSelect,
    this.backgroundColor,
  });

  final ClientSection section;
  final ValueChanged<ClientSection> onSearchSelect;
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    return SizedBox(
      height: StudioDesktopChromeMetrics.topBarHeight,
      child: ColoredBox(
        color: backgroundColor ?? colors.background,
        child: Center(
          child: StudioSidebarSearch(
            current: section,
            onSelect: onSearchSelect,
          ),
        ),
      ),
    );
  }
}

final class StudioSidebarSearch extends StatefulWidget {
  const StudioSidebarSearch({
    super.key,
    required this.current,
    required this.onSelect,
    this.width = 320,
  });

  final ClientSection current;
  final ValueChanged<ClientSection> onSelect;
  final double width;

  @override
  State<StudioSidebarSearch> createState() => _StudioSidebarSearchState();
}

final class _StudioSidebarSearchState extends State<StudioSidebarSearch> {
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

  List<_StudioSearchItem> _items(LicoStrings strings) => [
    for (final section in ClientSection.values)
      _StudioSearchItem(
        section: section,
        label: studioDesktopSectionTitle(strings, section),
        aliases: studioDesktopSectionSearchAliases(section),
      ),
  ];

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    final strings = LicoStrings.of(context);
    final items = _items(strings);
    const fieldHeight = 32.0;
    final pillRadius = fieldHeight / 2;
    final idleBorder = colors.line.withAlpha(colors.isDark ? 70 : 90);
    final focusBorder = colors.primaryStrong.withAlpha(200);

    return Focus(
      onKeyEvent: _handleKeyEvent,
      child: SizedBox(
        key: const Key('shell-sidebar-search'),
        width: widget.width,
        height: fieldHeight,
        child: Autocomplete<_StudioSearchItem>(
          displayStringForOption: (item) => item.label,
          optionsBuilder: (value) {
            final query = value.text.trim();
            if (query.isEmpty) {
              return const Iterable<_StudioSearchItem>.empty();
            }
            return items.where((item) => item.matches(query));
          },
          onSelected: (item) {
            widget.onSelect(item.section);
          },
          fieldViewBuilder:
              (context, textController, focusNode, onFieldSubmitted) {
                _bindFocus(focusNode);
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 140),
                  curve: Curves.easeOut,
                  height: fieldHeight,
                  width: widget.width,
                  alignment: Alignment.centerLeft,
                  decoration: BoxDecoration(
                    color: colors.isDark
                        ? colors.surface.withAlpha(180)
                        : colors.surface.withAlpha(220),
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
                          color: colors.textMuted,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: TextField(
                            controller: textController,
                            focusNode: focusNode,
                            cursorColor: colors.primaryStrong,
                            textAlign: TextAlign.start,
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
                              hintText: strings.sidebarSearchHint,
                              hintStyle: TextStyle(
                                color: colors.textMuted,
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
                  color: colors.surfaceLow,
                  borderRadius: BorderRadius.circular(14),
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
                            studioDesktopSectionIcon(item.section),
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

final class _StudioSearchItem {
  const _StudioSearchItem({
    required this.section,
    required this.label,
    required this.aliases,
  });

  final ClientSection section;
  final String label;
  final List<String> aliases;

  bool matches(String query) {
    final normalized = query.toLowerCase();
    return <String>[
      label,
      section.name,
      ...aliases,
    ].any((value) => value.toLowerCase().startsWith(normalized));
  }
}
