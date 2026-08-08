import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/features/agents/ui/history_session_header.dart';
import 'package:licoup/src/frontend/features/agents/ui/history_session_list.dart';
import 'package:licoup/src/frontend/features/agents/ui/history_session_models.dart';
import 'package:licoup/src/frontend/features/agents/ui/history_session_search.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

export 'package:licoup/src/frontend/features/agents/ui/history_session_models.dart';
export 'package:licoup/src/frontend/features/agents/ui/history_session_search.dart';

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

  /// When true, render project folders with nested sessions.
  final bool groupByProject;

  @override
  State<HistorySessionPanel> createState() => _HistorySessionPanelState();
}

final class _HistorySessionPanelState extends State<HistorySessionPanel> {
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
    final rowHeight = widget.groupByProject
        ? historySessionGroupedRowHeight
        : historySessionRowHeight;
    if (_scrollController.position.extentAfter <= rowHeight * 0.75) {
      widget.onLoadMore?.call();
    }
  }

  void _handleSearchChanged(String value) {
    setState(() => _searchQuery = value);
  }

  void _clearSearch() {
    if (_searchController.text.isEmpty) return;
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
    final labels = _HistorySessionLabels(
      empty: widget.emptyLabel ?? strings.noNativeHistories,
      loading: widget.loadingLabel ?? strings.loadingNativeHistories,
      noSearchResults:
          widget.noSearchResultsLabel ?? strings.noMatchingNativeHistories,
      loadMore: widget.loadMoreLabel ?? strings.scrollToLoadMoreHistories,
      loadingMore: widget.loadingMoreLabel ?? strings.loadingMoreHistories,
    );

    final content = LayoutBuilder(
      builder: (context, constraints) {
        final header = HistorySessionHeader(
          title: widget.title,
          subtitle: normalizedQuery.isEmpty
              ? widget.subtitle
              : '${visibleItems.length}/${widget.items.length}',
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
        final listRegion = ConstrainedBox(
          constraints: BoxConstraints(maxHeight: widget.maxListHeight),
          child: visibleItems.isEmpty
              ? _HistorySessionEmptyState(
                  label: widget.loading
                      ? labels.loading
                      : normalizedQuery.isEmpty
                      ? labels.empty
                      : labels.noSearchResults,
                )
              : HistorySessionList(
                  items: visibleItems,
                  groupedEntries: groupedEntries,
                  groupByProject: widget.groupByProject,
                  showLoadMore: showLoadMore,
                  loadingMore: widget.loadingMore,
                  loadMoreLabel: labels.loadMore,
                  loadingMoreLabel: labels.loadingMore,
                  controller: _scrollController,
                  onSelect: widget.onSelect,
                  onDelete: widget.onDelete,
                ),
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
    return DecoratedBox(
      decoration: BoxDecoration(
        color: colors.surface,
        border: widget.framed ? Border.all(color: colors.line) : null,
        borderRadius: widget.framed ? BorderRadius.circular(8) : null,
      ),
      child: content,
    );
  }
}

final class _HistorySessionLabels {
  const _HistorySessionLabels({
    required this.empty,
    required this.loading,
    required this.noSearchResults,
    required this.loadMore,
    required this.loadingMore,
  });

  final String empty;
  final String loading;
  final String noSearchResults;
  final String loadMore;
  final String loadingMore;
}

final class _HistorySessionEmptyState extends StatelessWidget {
  const _HistorySessionEmptyState({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          label,
          style: TextStyle(color: context.licoColors.textMuted),
        ),
      ),
    );
  }
}
