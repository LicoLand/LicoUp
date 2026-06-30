import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

import 'theme.dart';

const double _historySessionRowHeight = 84;

class HistorySessionPanelItem {
  const HistorySessionPanelItem({
    required this.id,
    required this.title,
    this.meta = '',
    this.preview = '',
    this.active = false,
    this.disabled = false,
    this.canDelete = true,
    this.deleteLabel = 'Delete native agent history',
  });

  final String id;
  final String title;
  final String meta;
  final String preview;
  final bool active;
  final bool disabled;
  final bool canDelete;
  final String deleteLabel;
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
    this.emptyLabel = 'No native agent histories yet',
    this.loadingLabel = 'Loading native agent histories...',
    this.initiallyExpanded = true,
    this.maxListHeight = 230,
  });

  final String title;
  final String subtitle;
  final List<HistorySessionPanelItem> items;
  final ValueChanged<String> onSelect;
  final ValueChanged<String>? onDelete;
  final bool loading;
  final String emptyLabel;
  final String loadingLabel;
  final bool initiallyExpanded;
  final double maxListHeight;

  @override
  State<HistorySessionPanel> createState() => _HistorySessionPanelState();
}

class _HistorySessionPanelState extends State<HistorySessionPanel> {
  late bool expanded = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: expanded ? colors.surface : colors.surfaceHigh,
        border: Border.all(color: colors.line),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => setState(() => expanded = !expanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Icon(
                    expanded ? Icons.expand_more : Icons.chevron_right,
                    size: 18,
                    color: colors.primary,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colors.text,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        Text(
                          widget.subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colors.textMuted,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (expanded) ...[
            if (widget.loading)
              LinearProgressIndicator(color: colors.primary)
            else
              const Divider(height: 1),
            ConstrainedBox(
              constraints: BoxConstraints(maxHeight: widget.maxListHeight),
              child: widget.items.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(14),
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          widget.loading
                              ? widget.loadingLabel
                              : widget.emptyLabel,
                          style: TextStyle(color: colors.textMuted),
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(10),
                      shrinkWrap: true,
                      scrollCacheExtent: ScrollCacheExtent.pixels(
                        _historySessionRowHeight * 4,
                      ),
                      itemBuilder: (context, index) {
                        final item = widget.items[index];
                        return _HistorySessionRow(
                          item: item,
                          onSelect: widget.onSelect,
                          onDelete: widget.onDelete,
                        );
                      },
                      separatorBuilder: (context, index) =>
                          const SizedBox(height: 8),
                      itemCount: widget.items.length,
                    ),
            ),
          ],
        ],
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
    final borderColor = item.active ? colors.primary : colors.line;
    final background = item.active ? colors.surfaceHigh : colors.surface;
    return Material(
      color: background,
      borderRadius: BorderRadius.circular(8),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: item.disabled ? null : () => onSelect(item.id),
        child: Container(
          height: _historySessionRowHeight,
          padding: const EdgeInsets.fromLTRB(12, 9, 8, 9),
          decoration: BoxDecoration(
            border: Border.all(color: borderColor),
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      item.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: colors.text,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    if (item.meta.isNotEmpty)
                      Text(
                        item.meta,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: colors.textMuted, fontSize: 12),
                      ),
                    if (item.preview.isNotEmpty)
                      Text(
                        item.preview,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(color: colors.textMuted, fontSize: 12),
                      ),
                  ],
                ),
              ),
              if (onDelete != null)
                IconButton(
                  tooltip: item.deleteLabel,
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
