import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/shared/ui/lico_activity_animations.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

const double _historySessionRowHeight = 72;
const double _historySessionGroupedRowHeight = 36;
const double _historySessionGroupHeaderHeight = 34;

class HistorySessionPanelItem {
  const HistorySessionPanelItem({
    required this.id,
    required this.title,
    this.meta = '',
    this.preview = '',
    this.groupKey = '',
    this.groupLabel = '',
    this.active = false,
    this.running = false,
    this.disabled = false,
    this.canDelete = true,
    this.deleteLabel,
  });

  final String id;
  final String title;
  final String meta;
  final String preview;

  /// Stable project/workspace key used for grouping (usually absolute cwd).
  final String groupKey;

  /// Display label for [groupKey] (usually the last path segment).
  final String groupLabel;
  final bool active;

  /// True while this session has an in-flight agent turn.
  final bool running;
  final bool disabled;
  final bool canDelete;
  final String? deleteLabel;
}

/// One render row in a project-grouped history list.
class HistorySessionListEntry {
  const HistorySessionListEntry.header({
    required this.groupKey,
    required this.groupLabel,
  }) : item = null,
       isHeader = true;

  const HistorySessionListEntry.item(this.item)
    : groupKey = '',
      groupLabel = '',
      isHeader = false;

  final bool isHeader;
  final String groupKey;
  final String groupLabel;
  final HistorySessionPanelItem? item;

  String get storageKey => isHeader
      ? _historySessionGroupStorageKey(groupKey)
      : _historySessionItemStorageKey(item!.id);
}

const String _historySessionLoadMoreStorageKey =
    'history-session-list-load-more';

String _historySessionItemStorageKey(String sessionId) => sessionId;

String _historySessionGroupStorageKey(String groupKey) {
  return 'history-session-list-group-${groupKey.hashCode.toUnsigned(32).toRadixString(16)}';
}

/// Basename of a working directory for project-group headers.
String historySessionProjectLabel(
  String workingDirectory, {
  String fallback = 'No project',
}) {
  final trimmed = workingDirectory.trim();
  if (trimmed.isEmpty) {
    return fallback;
  }
  final normalized = trimmed
      .replaceAll('\\', '/')
      .replaceAll(RegExp(r'/+$'), '');
  final parts = normalized
      .split('/')
      .where((part) => part.isNotEmpty)
      .toList(growable: false);
  if (parts.isEmpty) {
    return fallback;
  }
  return parts.last;
}

/// Groups sessions by [HistorySessionPanelItem.groupKey], preserving first-seen
/// order so the group with the newest activity stays on top when the input list
/// is already newest-first.
List<HistorySessionListEntry> historySessionGroupEntries(
  List<HistorySessionPanelItem> items, {
  String ungroupedLabel = 'No project',
}) {
  final groups = <String, List<HistorySessionPanelItem>>{};
  final labels = <String, String>{};
  for (final item in items) {
    final key = item.groupKey.trim();
    (groups[key] ??= <HistorySessionPanelItem>[]).add(item);
    labels.putIfAbsent(
      key,
      () => item.groupLabel.trim().isEmpty
          ? ungroupedLabel
          : item.groupLabel.trim(),
    );
  }
  final entries = <HistorySessionListEntry>[];
  for (final entry in groups.entries) {
    entries.add(
      HistorySessionListEntry.header(
        groupKey: entry.key,
        groupLabel: labels[entry.key] ?? ungroupedLabel,
      ),
    );
    for (final item in entry.value) {
      entries.add(HistorySessionListEntry.item(item));
    }
  }
  return entries;
}

class HistorySessionPanel extends StatefulWidget {
  const HistorySessionPanel({
    super.key,
    required this.title,
    required this.subtitle,
    required this.items,
    required this.onSelect,
    this.onDelete,
    this.loading = false,
    this.emptyLabel,
    this.loadingLabel,
    this.maxListHeight = 230,
    this.leading,
    this.trailing,
    this.framed = true,
    this.searchable = false,
    this.searchHint,
    this.noSearchResultsLabel,
    this.showHeaderText = true,
    this.collapsible = false,
    this.collapsed = false,
    this.collapseTooltip,
    this.expandTooltip,
    this.onCollapsedChanged,
    this.headerHeight,
    this.hasMore = false,
    this.loadingMore = false,
    this.onLoadMore,
    this.loadMoreLabel,
    this.loadingMoreLabel,
    this.groupByProject = false,
  });

  final String title;
  final String subtitle;
  final List<HistorySessionPanelItem> items;
  final ValueChanged<String> onSelect;
  final ValueChanged<String>? onDelete;
  final bool loading;
  final String? emptyLabel;
  final String? loadingLabel;
  final double maxListHeight;
  final Widget? leading;
  final Widget? trailing;
  final bool framed;
  final bool searchable;
  final String? searchHint;
  final String? noSearchResultsLabel;
  final bool showHeaderText;
  final bool collapsible;
  final bool collapsed;
  final String? collapseTooltip;
  final String? expandTooltip;
  final ValueChanged<bool>? onCollapsedChanged;
  final double? headerHeight;
  final bool hasMore;
  final bool loadingMore;
  final VoidCallback? onLoadMore;
  final String? loadMoreLabel;
  final String? loadingMoreLabel;

  /// When true, render Codex-style project folders with nested sessions.
  final bool groupByProject;

  @override
  State<HistorySessionPanel> createState() => _HistorySessionPanelState();
}

class _HistorySessionPanelState extends State<HistorySessionPanel> {
  late final TextEditingController _searchController;
  late final ScrollController _scrollController;
  String _searchQuery = '';
  late bool _collapsed;

  @override
  void initState() {
    super.initState();
    _searchController = TextEditingController();
    _scrollController = ScrollController()..addListener(_handleScroll);
    _collapsed = widget.collapsed;
  }

  @override
  void didUpdateWidget(covariant HistorySessionPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.collapsed != widget.collapsed) {
      _collapsed = widget.collapsed;
    }
  }

  @override
  void dispose() {
    _scrollController.removeListener(_handleScroll);
    _scrollController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  void _handleScroll() {
    if (!widget.hasMore ||
        widget.loadingMore ||
        widget.onLoadMore == null ||
        _searchQuery.trim().isNotEmpty ||
        !_scrollController.hasClients) {
      return;
    }
    final position = _scrollController.position;
    final rowHeight = widget.groupByProject
        ? _historySessionGroupedRowHeight
        : _historySessionRowHeight;
    if (position.extentAfter <= rowHeight * 0.75) {
      widget.onLoadMore?.call();
    }
  }

  void _handleSearchChanged(String value) {
    setState(() => _searchQuery = value);
  }

  void _clearSearch() {
    if (_searchController.text.isEmpty) {
      return;
    }
    _searchController.clear();
    _handleSearchChanged('');
  }

  void _toggleCollapsed() {
    final next = !_collapsed;
    setState(() => _collapsed = next);
    widget.onCollapsedChanged?.call(next);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final emptyLabel = widget.emptyLabel ?? strings.noNativeHistories;
    final loadingLabel = widget.loadingLabel ?? strings.loadingNativeHistories;
    final noSearchResultsLabel =
        widget.noSearchResultsLabel ?? strings.noMatchingNativeHistories;
    final loadMoreLabel =
        widget.loadMoreLabel ?? strings.scrollToLoadMoreHistories;
    final loadingMoreLabel =
        widget.loadingMoreLabel ?? strings.loadingMoreHistories;
    final normalizedQuery = _searchQuery.trim();
    final visibleItems = normalizedQuery.isEmpty
        ? widget.items
        : historySessionPrefixMatches(widget.items, normalizedQuery);
    final showLoadMore = normalizedQuery.isEmpty && widget.hasMore;
    final groupedEntries = widget.groupByProject
        ? historySessionGroupEntries(
            visibleItems,
            ungroupedLabel: strings.ungroupedConversationProject,
          )
        : const <HistorySessionListEntry>[];
    final flatIndexByStorageKey = <String, int>{
      for (var index = 0; index < visibleItems.length; index += 1)
        _historySessionItemStorageKey(visibleItems[index].id): index,
      if (showLoadMore) _historySessionLoadMoreStorageKey: visibleItems.length,
    };
    final groupedIndexByStorageKey = <String, int>{
      for (var index = 0; index < groupedEntries.length; index += 1)
        groupedEntries[index].storageKey: index,
      if (showLoadMore)
        _historySessionLoadMoreStorageKey: groupedEntries.length,
    };
    final content = LayoutBuilder(
      builder: (context, constraints) {
        final listRegion = ConstrainedBox(
          constraints: BoxConstraints(maxHeight: widget.maxListHeight),
          child: visibleItems.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(14),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      widget.loading
                          ? loadingLabel
                          : normalizedQuery.isEmpty
                          ? emptyLabel
                          : noSearchResultsLabel,
                      style: TextStyle(color: colors.textMuted),
                    ),
                  ),
                )
              : widget.groupByProject
              ? ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
                  shrinkWrap: true,
                  scrollCacheExtent: ScrollCacheExtent.pixels(
                    _historySessionGroupedRowHeight * 6 +
                        _historySessionGroupHeaderHeight * 2,
                  ),
                  findChildIndexCallback: (key) {
                    if (key case ValueKey<String>(:final value)) {
                      return groupedIndexByStorageKey[value];
                    }
                    return null;
                  },
                  itemBuilder: (context, index) {
                    if (index >= groupedEntries.length) {
                      return KeyedSubtree(
                        key: const ValueKey<String>(
                          _historySessionLoadMoreStorageKey,
                        ),
                        child: _HistorySessionLoadMoreRow(
                          label: widget.loadingMore
                              ? loadingMoreLabel
                              : loadMoreLabel,
                          loading: widget.loadingMore,
                        ),
                      );
                    }
                    final entry = groupedEntries[index];
                    if (entry.isHeader) {
                      return KeyedSubtree(
                        key: ValueKey<String>(entry.storageKey),
                        child: _HistorySessionProjectHeader(
                          label: entry.groupLabel,
                        ),
                      );
                    }
                    return KeyedSubtree(
                      key: ValueKey<String>(entry.storageKey),
                      child: _HistorySessionGroupedRow(
                        item: entry.item!,
                        onSelect: widget.onSelect,
                        onDelete: widget.onDelete,
                      ),
                    );
                  },
                  itemCount: groupedEntries.length + (showLoadMore ? 1 : 0),
                )
              : ListView.builder(
                  controller: _scrollController,
                  padding: EdgeInsets.zero,
                  shrinkWrap: true,
                  scrollCacheExtent: ScrollCacheExtent.pixels(
                    _historySessionRowHeight * 4,
                  ),
                  findChildIndexCallback: (key) {
                    if (key case ValueKey<String>(:final value)) {
                      return flatIndexByStorageKey[value];
                    }
                    return null;
                  },
                  itemBuilder: (context, index) {
                    if (index >= visibleItems.length) {
                      return KeyedSubtree(
                        key: const ValueKey<String>(
                          _historySessionLoadMoreStorageKey,
                        ),
                        child: _HistorySessionLoadMoreRow(
                          label: widget.loadingMore
                              ? loadingMoreLabel
                              : loadMoreLabel,
                          loading: widget.loadingMore,
                        ),
                      );
                    }
                    final item = visibleItems[index];
                    final itemCount =
                        visibleItems.length + (showLoadMore ? 1 : 0);
                    return KeyedSubtree(
                      key: ValueKey<String>(
                        _historySessionItemStorageKey(item.id),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _HistorySessionRow(
                            item: item,
                            onSelect: widget.onSelect,
                            onDelete: widget.onDelete,
                          ),
                          if (index + 1 < itemCount)
                            Divider(
                              height: 1,
                              color: colors.line.withAlpha(150),
                            ),
                        ],
                      ),
                    );
                  },
                  itemCount: visibleItems.length + (showLoadMore ? 1 : 0),
                ),
        );
        final searchResultLabel = normalizedQuery.isEmpty
            ? widget.subtitle
            : '${visibleItems.length}/${widget.items.length}';
        final header = _HistorySessionHeader(
          title: widget.title,
          subtitle: searchResultLabel,
          showHeaderText: widget.showHeaderText,
          searchable: widget.searchable,
          searchController: _searchController,
          searchHint: widget.searchHint ?? strings.searchHistories,
          searchQuery: _searchQuery,
          onSearchChanged: _handleSearchChanged,
          onClearSearch: _clearSearch,
          leading: widget.leading,
          trailing: widget.trailing,
          collapsible: widget.collapsible,
          collapsed: _collapsed,
          collapseTooltip: widget.collapseTooltip ?? strings.collapseHistory,
          expandTooltip: widget.expandTooltip ?? strings.expandHistory,
          onToggleCollapsed: _toggleCollapsed,
        );
        return Column(
          mainAxisSize: constraints.hasBoundedHeight
              ? MainAxisSize.max
              : MainAxisSize.min,
          children: [
            if (widget.headerHeight == null)
              header
            else
              SizedBox(height: widget.headerHeight, child: header),
            if (!_collapsed && widget.loading)
              LinearProgressIndicator(color: colors.primary)
            else if (!_collapsed)
              const Divider(height: 1),
            if (!_collapsed)
              if (constraints.hasBoundedHeight)
                Flexible(child: listRegion)
              else
                listRegion,
          ],
        );
      },
    );
    if (!widget.framed) {
      return DecoratedBox(
        decoration: BoxDecoration(color: colors.surface),
        child: content,
      );
    }
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(8),
      ),
      child: content,
    );
  }
}

class _HistorySessionLoadMoreRow extends StatelessWidget {
  const _HistorySessionLoadMoreRow({
    required this.label,
    required this.loading,
  });

  final String label;
  final bool loading;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return SizedBox(
      height: 44,
      child: Center(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (loading) ...[
              SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: colors.primary,
                ),
              ),
              const SizedBox(width: 8),
            ],
            Flexible(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.textMuted,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HistorySessionHeader extends StatelessWidget {
  const _HistorySessionHeader({
    required this.title,
    required this.subtitle,
    required this.showHeaderText,
    required this.searchable,
    required this.searchController,
    required this.searchHint,
    required this.searchQuery,
    required this.onSearchChanged,
    required this.onClearSearch,
    required this.leading,
    required this.trailing,
    required this.collapsible,
    required this.collapsed,
    required this.collapseTooltip,
    required this.expandTooltip,
    required this.onToggleCollapsed,
  });

  final String title;
  final String subtitle;
  final bool showHeaderText;
  final bool searchable;
  final TextEditingController searchController;
  final String searchHint;
  final String searchQuery;
  final ValueChanged<String> onSearchChanged;
  final VoidCallback onClearSearch;
  final Widget? leading;
  final Widget? trailing;
  final bool collapsible;
  final bool collapsed;
  final String collapseTooltip;
  final String expandTooltip;
  final VoidCallback onToggleCollapsed;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final iconOnlyCollapsedHeader = collapsed && !showHeaderText && !searchable;
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: 16,
        vertical: iconOnlyCollapsedHeader ? 0 : 8,
      ),
      child: Row(
        children: [
          if (!collapsed && leading != null) ...[
            leading!,
            const SizedBox(width: 8),
          ],
          Expanded(
            child: searchable
                ? TextField(
                    controller: searchController,
                    onChanged: onSearchChanged,
                    textInputAction: TextInputAction.search,
                    style: TextStyle(color: colors.text, fontSize: 13),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: searchHint,
                      hintStyle: TextStyle(color: colors.textMuted),
                      prefixIcon: Icon(
                        Icons.search,
                        size: 18,
                        color: colors.textMuted,
                      ),
                      suffixIcon: searchQuery.isEmpty
                          ? null
                          : IconButton(
                              tooltip: strings.clearSearch,
                              onPressed: onClearSearch,
                              icon: const Icon(Icons.close, size: 16),
                            ),
                      filled: true,
                      fillColor: colors.surfaceHigh,
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 10,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: colors.line),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: colors.line),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(8),
                        borderSide: BorderSide(color: colors.primary),
                      ),
                    ),
                  )
                : showHeaderText
                ? Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: colors.text,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      Text(
                        subtitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: colors.textMuted, fontSize: 12),
                      ),
                    ],
                  )
                : const SizedBox.shrink(),
          ),
          if (searchable) ...[
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 82),
              child: Text(
                subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.right,
                style: TextStyle(color: colors.textMuted, fontSize: 12),
              ),
            ),
          ],
          if (!collapsed && trailing != null) ...[
            const SizedBox(width: 8),
            trailing!,
          ],
          if (collapsible) ...[
            const SizedBox(width: 8),
            IconButton(
              tooltip: collapsed ? expandTooltip : collapseTooltip,
              onPressed: onToggleCollapsed,
              color: colors.primary,
              hoverColor: Color.lerp(colors.surface, colors.primary, 0.12),
              style: IconButton.styleFrom(
                fixedSize: const Size(32, 32),
                minimumSize: const Size(32, 32),
                padding: EdgeInsets.zero,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              icon: Icon(
                collapsed
                    ? Icons.keyboard_double_arrow_right_rounded
                    : Icons.keyboard_double_arrow_left_rounded,
                size: 18,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

List<HistorySessionPanelItem> historySessionPrefixMatches(
  List<HistorySessionPanelItem> items,
  String query,
) {
  final terms = _historySearchTerms(query);
  if (terms.isEmpty) {
    return items;
  }
  final ranked = <_HistorySessionSearchMatch>[];
  for (var index = 0; index < items.length; index++) {
    final score = _historySessionMatchScore(items[index], terms);
    if (score != null) {
      ranked.add(
        _HistorySessionSearchMatch(
          item: items[index],
          originalIndex: index,
          score: score,
        ),
      );
    }
  }
  ranked.sort((a, b) {
    final scoreOrder = a.score.compareTo(b.score);
    return scoreOrder == 0
        ? a.originalIndex.compareTo(b.originalIndex)
        : scoreOrder;
  });
  return ranked.map((match) => match.item).toList(growable: false);
}

class _HistorySessionSearchMatch {
  const _HistorySessionSearchMatch({
    required this.item,
    required this.originalIndex,
    required this.score,
  });

  final HistorySessionPanelItem item;
  final int originalIndex;
  final int score;
}

final RegExp _historySearchSeparators = RegExp(r'[\s\/\\._:;,+()\[\]{}<>|\-]+');
final RegExp _historySearchWord = RegExp(r'[a-z0-9]+');

List<String> _historySearchTerms(String query) {
  return query
      .toLowerCase()
      .split(_historySearchSeparators)
      .map((term) => term.trim())
      .where((term) => term.isNotEmpty)
      .toList(growable: false);
}

int? _historySessionMatchScore(
  HistorySessionPanelItem item,
  List<String> terms,
) {
  var totalScore = 0;
  for (final term in terms) {
    final termScore =
        [
          _historyFieldMatchScore(item.title, term, 0),
          _historyFieldMatchScore(item.groupLabel, term, 40),
          _historyFieldMatchScore(item.meta, term, 80),
          _historyFieldMatchScore(item.preview, term, 120),
        ].whereType<int>().fold<int?>(
          null,
          (best, score) => best == null || score < best ? score : best,
        );
    if (termScore == null) {
      return null;
    }
    totalScore += termScore;
  }
  return totalScore;
}

int? _historyFieldMatchScore(String value, String term, int fieldWeight) {
  final text = value.toLowerCase();
  if (text.isEmpty) {
    return null;
  }
  if (text == term) {
    return fieldWeight;
  }
  if (text.startsWith(term)) {
    return fieldWeight + 1;
  }
  for (final match in _historySearchWord.allMatches(text)) {
    final word = match.group(0);
    if (word != null && word.startsWith(term)) {
      return fieldWeight + 20 + match.start;
    }
  }
  final containsAt = text.indexOf(term);
  if (containsAt >= 0) {
    return fieldWeight + 200 + containsAt;
  }
  return null;
}

class _HistorySessionProjectHeader extends StatelessWidget {
  const _HistorySessionProjectHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return SizedBox(
      height: _historySessionGroupHeaderHeight,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(10, 10, 10, 2),
        child: Row(
          children: [
            Icon(Icons.folder_outlined, size: 15, color: colors.textMuted),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: colors.text,
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HistorySessionGroupedRow extends StatelessWidget {
  const _HistorySessionGroupedRow({
    required this.item,
    required this.onSelect,
    required this.onDelete,
  });

  final HistorySessionPanelItem item;
  final ValueChanged<String> onSelect;
  final ValueChanged<String>? onDelete;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final background = item.active
        ? (Color.lerp(colors.surface, colors.primary, 0.14) ??
              colors.surfaceHigh)
        : Colors.transparent;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
      child: Material(
        key: Key('history-session-row-${item.id}'),
        color: background,
        borderRadius: BorderRadius.circular(8),
        child: InkWell(
          onTap: item.disabled ? null : () => onSelect(item.id),
          borderRadius: BorderRadius.circular(8),
          child: SizedBox(
            height: _historySessionGroupedRowHeight,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(28, 0, 6, 0),
              child: Row(
                children: [
                  Expanded(
                    child: item.running
                        ? LicoShimmerText(
                            text: item.title,
                            enabled: true,
                            style: TextStyle(
                              color: colors.text,
                              fontSize: 13,
                              fontWeight: item.active
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                            ),
                          )
                        : Text(
                            item.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: colors.text,
                              fontSize: 13,
                              fontWeight: item.active
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                            ),
                          ),
                  ),
                  if (item.running) ...[
                    const SizedBox(width: 8),
                    LicoSpinningRefreshIcon(size: 12, color: colors.textMuted),
                  ] else if (item.meta.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    Text(
                      item.meta,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.textMuted.withAlpha(180),
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                  if (onDelete != null)
                    IconButton(
                      tooltip: item.deleteLabel ?? strings.deleteNativeHistory,
                      onPressed: item.disabled || !item.canDelete
                          ? null
                          : () => onDelete?.call(item.id),
                      color: colors.textMuted,
                      hoverColor: Color.lerp(
                        colors.surface,
                        colors.error,
                        0.12,
                      ),
                      visualDensity: VisualDensity.compact,
                      constraints: const BoxConstraints(
                        minWidth: 28,
                        minHeight: 28,
                      ),
                      padding: EdgeInsets.zero,
                      icon: const Icon(Icons.delete_outline, size: 16),
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

class _HistorySessionRow extends StatelessWidget {
  const _HistorySessionRow({
    required this.item,
    required this.onSelect,
    required this.onDelete,
  });

  final HistorySessionPanelItem item;
  final ValueChanged<String> onSelect;
  final ValueChanged<String>? onDelete;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final background = item.active
        ? Color.lerp(colors.surface, colors.primary, 0.10) ?? colors.surfaceHigh
        : colors.surface;
    return Material(
      key: Key('history-session-row-${item.id}'),
      color: background,
      child: InkWell(
        onTap: item.disabled ? null : () => onSelect(item.id),
        child: SizedBox(
          height: _historySessionRowHeight,
          child: Row(
            children: [
              SizedBox(
                width: 3,
                height: double.infinity,
                child: ColoredBox(
                  color: item.active ? colors.primary : Colors.transparent,
                ),
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 8, 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      item.running
                          ? LicoShimmerText(
                              text: item.title,
                              style: TextStyle(
                                color: colors.text,
                                fontWeight: FontWeight.w700,
                              ),
                            )
                          : Text(
                              item.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: colors.text,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                      if (item.preview.isNotEmpty) const SizedBox(height: 2),
                      if (item.preview.isNotEmpty)
                        Text(
                          item.preview,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colors.textMuted,
                            fontSize: 12,
                          ),
                        ),
                      if (item.meta.isNotEmpty) const Spacer(),
                      if (item.meta.isNotEmpty)
                        Text(
                          item.meta,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colors.textMuted.withAlpha(170),
                            fontSize: 11,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (item.running)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: LicoSpinningRefreshIcon(
                    size: 13,
                    color: colors.textMuted,
                  ),
                ),
              if (onDelete != null)
                IconButton(
                  tooltip: item.deleteLabel ?? strings.deleteNativeHistory,
                  onPressed: item.disabled || !item.canDelete
                      ? null
                      : () => onDelete?.call(item.id),
                  color: colors.textMuted,
                  hoverColor: Color.lerp(colors.surface, colors.error, 0.12),
                  icon: const Icon(Icons.delete_outline, size: 18),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
