import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';

const double _searchFieldHeight = 28;
const double _searchCornerRadius = 10;

final class DashboardDesktopSearch extends StatefulWidget {
  const DashboardDesktopSearch({
    super.key,
    required this.current,
    required this.onSelect,
    required this.width,
  });

  final ClientSection current;
  final ValueChanged<ClientSection> onSelect;
  final double width;

  @override
  State<DashboardDesktopSearch> createState() => _DashboardDesktopSearchState();
}

final class _DashboardDesktopSearchState extends State<DashboardDesktopSearch> {
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
        _DashboardSearchItem(
          section: section,
          label: _sectionTitle(strings, section),
          aliases: _sectionSearchAliases(section),
        ),
    ];
    final borderColor = _focused
        ? colors.primaryStrong.withAlpha(200)
        : colors.line.withAlpha(colors.isDark ? 90 : 120);

    return Focus(
      onKeyEvent: _handleKeyEvent,
      child: SizedBox(
        key: const Key('shell-global-search'),
        width: widget.width,
        height: _searchFieldHeight + 8,
        child: Autocomplete<_DashboardSearchItem>(
          displayStringForOption: (item) => item.label,
          optionsBuilder: (value) {
            final query = value.text.trim();
            if (query.isEmpty) {
              return const Iterable<_DashboardSearchItem>.empty();
            }
            return items.where((item) => item.matches(query));
          },
          onSelected: (item) => widget.onSelect(item.section),
          fieldViewBuilder:
              (context, textController, focusNode, onFieldSubmitted) {
                _bindFocus(focusNode);
                final fieldHeight = _searchFieldHeight + 8.0;
                final horizontalInset = fieldHeight * 0.28;
                final iconGap = fieldHeight * 0.18;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 140),
                  curve: Curves.easeOut,
                  height: fieldHeight,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: colors.surfaceLow,
                    borderRadius: BorderRadius.circular(_searchCornerRadius),
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
                          child: Transform.translate(
                            // Optical compensation: the collapsed TextField
                            // parks CJK ink ~2pt below the row's optical
                            // center; measured against the search icon.
                            offset: const Offset(0, -4),
                            child: TextField(
                              controller: textController,
                              focusNode: focusNode,
                              cursorColor: colors.accent,
                              textAlignVertical: TextAlignVertical.center,
                              strutStyle: const StrutStyle(
                                fontSize: 13,
                                height: 1.25,
                                forceStrutHeight: true,
                                leadingDistribution:
                                    TextLeadingDistribution.even,
                              ),
                              style: TextStyle(
                                color: colors.text,
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
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
                  borderRadius: BorderRadius.circular(_searchCornerRadius),
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

final class _DashboardSearchItem {
  const _DashboardSearchItem({
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

String _sectionTitle(LicoStrings strings, ClientSection section) =>
    switch (section) {
      ClientSection.agents => strings.agents,
      ClientSection.monitoring => strings.tokenUsage,
      ClientSection.skillHub => strings.skillHub,
      ClientSection.pluginManagement => strings.pluginManagement,
      ClientSection.mobileRelay => strings.mobileRelay,
      ClientSection.models => strings.keys,
      ClientSection.settings => strings.settings,
    };

IconData _sectionIcon(ClientSection section) => switch (section) {
  ClientSection.agents => Icons.psychology_outlined,
  ClientSection.monitoring => Icons.query_stats_outlined,
  ClientSection.skillHub => Icons.library_books_outlined,
  ClientSection.pluginManagement => Icons.extension_outlined,
  ClientSection.mobileRelay => Icons.phonelink_outlined,
  ClientSection.models => Icons.key_outlined,
  ClientSection.settings => Icons.settings_outlined,
};

List<String> _sectionSearchAliases(ClientSection section) => switch (section) {
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
      ClientSection.mobileRelay => ['mobile', 'relay', 'pair', '配对', '通信'],
  ClientSection.models => ['model', 'api', 'key', 'gateway', '模型', '密钥', '网关'],
  ClientSection.settings => ['setting', 'preference', '设置'],
};
