import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'package:licoup/src/frontend/features/agents/ui/history_session_models.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/lico_activity_animations.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

final class HistorySessionList extends StatelessWidget {
  const HistorySessionList({
    super.key,
    required this.items,
    required this.groupedEntries,
    required this.groupByProject,
    required this.showLoadMore,
    required this.loadingMore,
    required this.loadMoreLabel,
    required this.loadingMoreLabel,
    required this.controller,
    required this.onSelect,
    required this.onDelete,
  });

  final List<HistorySessionPanelItem> items;
  final List<HistorySessionListEntry> groupedEntries;
  final bool groupByProject;
  final bool showLoadMore;
  final bool loadingMore;
  final String loadMoreLabel;
  final String loadingMoreLabel;
  final ScrollController controller;
  final ValueChanged<String> onSelect;
  final ValueChanged<String>? onDelete;

  @override
  Widget build(BuildContext context) {
    return groupByProject ? _buildGrouped() : _buildFlat(context);
  }

  Widget _buildGrouped() {
    final indexByStorageKey = <String, int>{
      for (var index = 0; index < groupedEntries.length; index += 1)
        groupedEntries[index].storageKey: index,
      if (showLoadMore) historySessionLoadMoreStorageKey: groupedEntries.length,
    };
    return ListView.builder(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
      shrinkWrap: true,
      scrollCacheExtent: ScrollCacheExtent.pixels(
        historySessionGroupedRowHeight * 6 +
            historySessionGroupHeaderHeight * 2,
      ),
      findChildIndexCallback: (key) => _indexForKey(key, indexByStorageKey),
      itemBuilder: (context, index) {
        if (index >= groupedEntries.length) {
          return KeyedSubtree(
            key: const ValueKey<String>(historySessionLoadMoreStorageKey),
            child: HistorySessionLoadMoreRow(
              label: loadingMore ? loadingMoreLabel : loadMoreLabel,
              loading: loadingMore,
            ),
          );
        }
        final entry = groupedEntries[index];
        return KeyedSubtree(
          key: ValueKey<String>(entry.storageKey),
          child: entry.isHeader
              ? HistorySessionProjectHeader(label: entry.groupLabel)
              : HistorySessionGroupedRow(
                  item: entry.item!,
                  onSelect: onSelect,
                  onDelete: onDelete,
                ),
        );
      },
      itemCount: groupedEntries.length + (showLoadMore ? 1 : 0),
    );
  }

  Widget _buildFlat(BuildContext context) {
    final colors = context.licoColors;
    final indexByStorageKey = <String, int>{
      for (var index = 0; index < items.length; index += 1)
        historySessionItemStorageKey(items[index].id): index,
      if (showLoadMore) historySessionLoadMoreStorageKey: items.length,
    };
    final itemCount = items.length + (showLoadMore ? 1 : 0);
    return ListView.builder(
      controller: controller,
      padding: EdgeInsets.zero,
      shrinkWrap: true,
      scrollCacheExtent: ScrollCacheExtent.pixels(historySessionRowHeight * 4),
      findChildIndexCallback: (key) => _indexForKey(key, indexByStorageKey),
      itemBuilder: (context, index) {
        if (index >= items.length) {
          return KeyedSubtree(
            key: const ValueKey<String>(historySessionLoadMoreStorageKey),
            child: HistorySessionLoadMoreRow(
              label: loadingMore ? loadingMoreLabel : loadMoreLabel,
              loading: loadingMore,
            ),
          );
        }
        final item = items[index];
        return KeyedSubtree(
          key: ValueKey<String>(historySessionItemStorageKey(item.id)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              HistorySessionRow(
                item: item,
                onSelect: onSelect,
                onDelete: onDelete,
              ),
              if (index + 1 < itemCount)
                Divider(height: 1, color: colors.line.withAlpha(150)),
            ],
          ),
        );
      },
      itemCount: itemCount,
    );
  }

  int? _indexForKey(Key key, Map<String, int> indexes) {
    if (key case ValueKey<String>(:final value)) return indexes[value];
    return null;
  }
}

final class HistorySessionLoadMoreRow extends StatelessWidget {
  const HistorySessionLoadMoreRow({
    super.key,
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

final class HistorySessionProjectHeader extends StatelessWidget {
  const HistorySessionProjectHeader({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return SizedBox(
      height: historySessionGroupHeaderHeight,
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

final class HistorySessionGroupedRow extends StatelessWidget {
  const HistorySessionGroupedRow({
    super.key,
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
            height: historySessionGroupedRowHeight,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(28, 0, 6, 0),
              child: Row(
                children: [
                  Expanded(child: _HistorySessionTitle(item: item)),
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

final class HistorySessionRow extends StatelessWidget {
  const HistorySessionRow({
    super.key,
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
          height: historySessionRowHeight,
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
                      _HistorySessionTitle(item: item, bold: true),
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

final class _HistorySessionTitle extends StatelessWidget {
  const _HistorySessionTitle({required this.item, this.bold = false});

  final HistorySessionPanelItem item;
  final bool bold;

  @override
  Widget build(BuildContext context) {
    final style = TextStyle(
      color: context.licoColors.text,
      fontSize: bold ? null : 13,
      fontWeight: bold || item.active ? FontWeight.w700 : FontWeight.w500,
    );
    return item.running
        ? LicoShimmerText(text: item.title, enabled: true, style: style)
        : Text(
            item.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: style,
          );
  }
}
