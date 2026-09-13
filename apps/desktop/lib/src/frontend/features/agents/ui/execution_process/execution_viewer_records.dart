import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

import 'execution_document.dart';

/// Renders only visible, exactly measured paragraphs from the complete input.
class ExecutionViewerRecords extends StatelessWidget {
  const ExecutionViewerRecords({
    super.key,
    required this.document,
    required this.scrollController,
    required this.matches,
    required this.matchIndex,
    required this.preparing,
    required this.showLatest,
    required this.onScroll,
    required this.onBackToLatest,
    required this.onCopyText,
    required this.onSelectedTextChanged,
    required this.onCopySelection,
  });

  final ExecutionDocument document;
  final ScrollController scrollController;
  final List<ExecutionSearchMatch> matches;
  final int matchIndex;
  final bool preparing;
  final bool showLatest;
  final bool Function(ScrollNotification) onScroll;
  final VoidCallback onBackToLatest;
  final Future<void> Function(String) onCopyText;
  final ValueChanged<String> onSelectedTextChanged;
  final VoidCallback onCopySelection;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return Stack(
      children: [
        Positioned.fill(
          child: ExecutionViewerSelection(
            onCopySelection: onCopySelection,
            onSelectedTextChanged: onSelectedTextChanged,
            child: NotificationListener<ScrollNotification>(
              onNotification: onScroll,
              child: Scrollbar(
                controller: scrollController,
                child: ListView.builder(
                  key: const Key('execution-process-records'),
                  controller: scrollController,
                  padding: const EdgeInsets.only(bottom: 68),
                  itemCount: document.rows.length,
                  itemExtentBuilder: (index, _) => index < document.rows.length
                      ? document.rows[index].height
                      : null,
                  itemBuilder: (context, index) =>
                      _buildDocumentRow(context, document, index),
                ),
              ),
            ),
          ),
        ),
        if (preparing)
          Positioned(
            top: 4,
            right: 18,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: colors.surface,
                  borderRadius: BorderRadius.circular(LicoRadius.chip),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Text(
                    strings.executionProcessPreparing,
                    key: const Key('execution-process-preparing'),
                    style: TextStyle(color: colors.textMuted, fontSize: 12),
                  ),
                ),
              ),
            ),
          ),
        if (showLatest)
          Positioned(
            bottom: 14,
            right: 18,
            child: FilledButton.tonalIcon(
              key: const Key('execution-process-latest'),
              onPressed: onBackToLatest,
              icon: const Icon(Icons.arrow_downward_rounded, size: 17),
              label: Text(strings.executionProcessLatest),
              style: FilledButton.styleFrom(
                backgroundColor: colors.surfaceRaised,
                foregroundColor: colors.text,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildDocumentRow(
    BuildContext context,
    ExecutionDocument document,
    int index,
  ) {
    final row = document.rows[index];
    final record = document.records[row.recordIndex];
    final colors = context.licoColors;
    if (row.isHeader) {
      return SelectionContainer.disabled(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    document.headerLabels[row.recordIndex],
                    style: document.headerStyle,
                    textScaler: document.textScaler,
                  ),
                ),
              ),
              const SizedBox(width: 16),
              IconButton(
                key: ValueKey('execution-process-copy-${record.id}'),
                tooltip: LicoStrings.of(context).executionProcessCopyRecord,
                onPressed: () => unawaited(onCopyText(record.rawText)),
                constraints: const BoxConstraints(minWidth: 40, minHeight: 40),
                icon: Icon(
                  Icons.copy_outlined,
                  size: 16,
                  color: colors.textMuted,
                ),
              ),
            ],
          ),
        ),
      );
    }
    final chunk = row.chunk!;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18),
      child: Text.rich(
        _highlightedText(context, document, row),
        key: ValueKey('execution-process-text-${record.id}-${chunk.start}'),
        style: document.textStyle,
        textScaler: document.textScaler,
        textDirection: document.direction,
        locale: document.locale,
      ),
    );
  }

  TextSpan _highlightedText(
    BuildContext context,
    ExecutionDocument document,
    ExecutionDocumentRow row,
  ) {
    final chunk = row.chunk!;
    final raw = document.records[row.recordIndex].rawText;
    final spans = <TextSpan>[];
    var cursor = chunk.start;
    var low = 0;
    var high = matches.length;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      final match = matches[middle];
      if (match.recordIndex < row.recordIndex ||
          (match.recordIndex == row.recordIndex && match.end <= chunk.start)) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    for (var index = low; index < matches.length; index++) {
      final match = matches[index];
      if (match.recordIndex != row.recordIndex || match.start >= chunk.end) {
        break;
      }
      final start = math.max(chunk.start, match.start);
      final end = math.min(chunk.end, match.end);
      if (cursor < start) {
        spans.add(TextSpan(text: raw.substring(cursor, start)));
      }
      final colors = context.licoColors;
      spans.add(
        TextSpan(
          text: raw.substring(start, end),
          style: TextStyle(
            backgroundColor: index == matchIndex
                ? colors.primary
                : colors.accentSurface,
            color: index == matchIndex ? colors.textOnPrimary : colors.text,
          ),
        ),
      );
      cursor = end;
    }
    if (cursor < chunk.end) {
      spans.add(TextSpan(text: raw.substring(cursor, chunk.end)));
    }
    return TextSpan(children: spans);
  }
}

/// Keeps keyboard and contextual copying on the caller's platform callback.
class ExecutionViewerSelection extends StatelessWidget {
  const ExecutionViewerSelection({
    super.key,
    required this.onCopySelection,
    required this.onSelectedTextChanged,
    required this.child,
  });

  final VoidCallback onCopySelection;
  final ValueChanged<String> onSelectedTextChanged;
  final Widget child;

  @override
  Widget build(BuildContext context) => Actions(
    actions: {
      CopySelectionTextIntent: CallbackAction<CopySelectionTextIntent>(
        onInvoke: (_) {
          onCopySelection();
          return null;
        },
      ),
    },
    child: SelectionArea(
      onSelectionChanged: (content) =>
          onSelectedTextChanged(content?.plainText ?? ''),
      contextMenuBuilder: (context, state) =>
          AdaptiveTextSelectionToolbar.buttonItems(
            anchors: state.contextMenuAnchors,
            buttonItems: [
              for (final item in state.contextMenuButtonItems)
                if (item.type == ContextMenuButtonType.copy)
                  ContextMenuButtonItem(
                    type: ContextMenuButtonType.copy,
                    onPressed: () {
                      onCopySelection();
                      state.hideToolbar();
                    },
                  )
                else if (item.type != ContextMenuButtonType.share)
                  item,
            ],
          ),
      child: child,
    ),
  );
}
