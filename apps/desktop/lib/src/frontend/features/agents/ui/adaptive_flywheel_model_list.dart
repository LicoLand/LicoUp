import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/features/agents/ui/adaptive_flywheel_renderer_models.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// The model column keeps native catalog order and lays out only viewport rows.
/// Text extents are prepared when its content or typography changes, so a saved
/// selection can be revealed without constructing all preceding widgets.
final class AgentRuntimeModelList extends StatefulWidget {
  const AgentRuntimeModelList({
    super.key,
    required this.keyPrefix,
    required this.agentId,
    required this.catalog,
    required this.query,
    required this.selectedModel,
    required this.maxHeight,
    required this.onModelEnter,
    required this.onModelSelected,
    required this.emptyLabel,
    this.revealSelectionOnOpen = false,
  });

  final String keyPrefix;
  final String agentId;
  final AgentOrchestrationModelCatalog catalog;
  final String query;
  final String selectedModel;
  final double maxHeight;
  final ValueChanged<String> onModelEnter;
  final ValueChanged<String> onModelSelected;
  final String emptyLabel;
  final bool revealSelectionOnOpen;

  @override
  State<AgentRuntimeModelList> createState() => _AgentRuntimeModelListState();
}

final class _AgentRuntimeModelListState extends State<AgentRuntimeModelList> {
  final _scrollController = ScrollController();
  final _rows = <({String label, String? model, Key key})>[];
  final _indexByKey = <Key, int>{};
  final _offsets = <double>[];
  AgentOrchestrationModelCatalog? _catalog;
  String? _query;
  Object? _layoutInputs;
  bool _revealPending = true;
  bool _revealScheduled = false;

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _updateRows() {
    final query = widget.query.trim().toLowerCase();
    if (identical(_catalog, widget.catalog) && _query == query) return;
    _catalog = widget.catalog;
    _query = query;
    _layoutInputs = null;
    _rows.clear();
    _indexByKey.clear();
    for (final group in widget.catalog.matchingGroups(query)) {
      if (group.providerLabel.isNotEmpty) {
        _rows.add((
          label: group.providerLabel,
          model: null,
          key: Key(
            '${widget.keyPrefix}-provider-${widget.agentId}-${group.providerId.isNotEmpty ? group.providerId : group.providerLabel}',
          ),
        ));
      }
      for (final model in group.models) {
        _rows.add((
          label: widget.catalog.displayName(model),
          model: model,
          key: Key('${widget.keyPrefix}-model-${widget.agentId}-$model'),
        ));
      }
    }
    for (var index = 0; index < _rows.length; index++) {
      _indexByKey[_rows[index].key] = index;
    }
  }

  void _prepareLayout(BuildContext context, double width) {
    final baseStyle = DefaultTextStyle.of(context).style;
    final textScaler = MediaQuery.textScalerOf(context);
    final direction = Directionality.of(context);
    final locale = Localizations.maybeLocaleOf(context);
    final inputs = (
      width,
      baseStyle,
      textScaler,
      direction,
      locale,
      widget.selectedModel,
    );
    if (_layoutInputs == inputs) return;
    _layoutInputs = inputs;
    _offsets.clear();
    _offsets.add(0);
    final painter = TextPainter(
      textDirection: direction,
      textScaler: textScaler,
      locale: locale,
    );
    for (final row in _rows) {
      final isHeader = row.model == null;
      final selected = row.model == widget.selectedModel;
      painter
        ..maxLines = isHeader ? null : 4
        ..text = TextSpan(
          text: row.label,
          style: baseStyle.merge(_rowStyle(isHeader, selected)),
        )
        ..layout(maxWidth: math.max(1, width - 24 - (selected ? 15 : 0)));
      final height = isHeader
          ? painter.height + 12
          : math.max(painter.height, selected ? 15.0 : 0.0) + 16;
      _offsets.add(_offsets.last + height);
    }
    painter.dispose();
  }

  void _revealSelection() {
    if (!widget.revealSelectionOnOpen ||
        !_revealPending ||
        _revealScheduled ||
        widget.selectedModel.isEmpty) {
      return;
    }
    final index =
        _indexByKey[Key(
          '${widget.keyPrefix}-model-${widget.agentId}-${widget.selectedModel}',
        )];
    if (index == null) return;
    _revealScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _revealScheduled = false;
      if (!mounted || !_scrollController.hasClients) return;
      _revealPending = false;
      final position = _scrollController.position;
      final offset =
          (_offsets[index] + _offsets[index + 1] - position.viewportDimension) /
          2;
      _scrollController.jumpTo(
        offset.clamp(position.minScrollExtent, position.maxScrollExtent),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    _updateRows();
    final colors = context.licoColors;
    if (_rows.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        child: Text(
          widget.emptyLabel,
          style: TextStyle(color: colors.textMuted, fontSize: 12.5),
        ),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        _prepareLayout(context, constraints.maxWidth);
        _revealSelection();
        return SizedBox(
          height: math.min(widget.maxHeight, _offsets.last + 6),
          child: ListView.custom(
            key: Key('${widget.keyPrefix}-model-list'),
            controller: _scrollController,
            padding: const EdgeInsets.only(bottom: 6),
            itemExtentBuilder: (index, _) => index < _rows.length
                ? _offsets[index + 1] - _offsets[index]
                : null,
            childrenDelegate: _ModelRowsDelegate(
              totalExtent: _offsets.last,
              childCount: _rows.length,
              findChildIndexCallback: (key) => _indexByKey[key],
              (context, index) {
                final row = _rows[index];
                final model = row.model;
                if (model == null) {
                  return Padding(
                    key: row.key,
                    padding: const EdgeInsets.fromLTRB(12, 9, 12, 3),
                    child: Text(
                      row.label,
                      style: _rowStyle(
                        true,
                        false,
                      ).copyWith(color: colors.textMuted),
                    ),
                  );
                }
                final selected = model == widget.selectedModel;
                return MouseRegion(
                  key: row.key,
                  onEnter: (_) => widget.onModelEnter(model),
                  child: InkWell(
                    onTap: () => widget.onModelSelected(model),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Text(
                              row.label,
                              maxLines: 4,
                              softWrap: true,
                              overflow: TextOverflow.visible,
                              style: _rowStyle(
                                false,
                                selected,
                              ).copyWith(color: colors.text),
                            ),
                          ),
                          if (selected)
                            Icon(
                              Icons.check_rounded,
                              size: 15,
                              color: colors.accent,
                            ),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        );
      },
    );
  }

  static TextStyle _rowStyle(bool isHeader, bool selected) => TextStyle(
    fontSize: isHeader ? 11 : 12.5,
    fontWeight: isHeader || selected ? FontWeight.w600 : FontWeight.w500,
    height: isHeader ? 14 / 11 : null,
  );
}

/// The complete extents are already known. Supplying their sum avoids the
/// framework's sampled-height estimate moving the scrollbar or saved reveal.
final class _ModelRowsDelegate extends SliverChildBuilderDelegate {
  _ModelRowsDelegate(
    super.builder, {
    required this.totalExtent,
    required super.childCount,
    super.findChildIndexCallback,
  });

  final double totalExtent;

  @override
  double estimateMaxScrollOffset(
    int firstIndex,
    int lastIndex,
    double leadingScrollOffset,
    double trailingScrollOffset,
  ) => totalExtent;
}
