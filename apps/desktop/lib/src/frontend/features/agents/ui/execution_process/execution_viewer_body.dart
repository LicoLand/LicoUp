import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

import 'conversation_execution_models.dart';
import 'execution_document.dart';
import 'execution_viewer_records.dart';

class ExecutionViewerBody extends StatelessWidget {
  const ExecutionViewerBody({
    super.key,
    required this.snapshot,
    required this.document,
    required this.requestedDocument,
    required this.scrollController,
    required this.matches,
    required this.matchIndex,
    required this.showLatest,
    required this.onDocumentRequested,
    required this.onPreparing,
    required this.onScroll,
    required this.onBackToLatest,
    required this.onCopyText,
    required this.onSelectedTextChanged,
    required this.onCopySelection,
  });

  final ConversationExecutionSnapshot snapshot;
  final ExecutionDocument? document;
  final ExecutionDocument? requestedDocument;
  final ScrollController scrollController;
  final List<ExecutionSearchMatch> matches;
  final int matchIndex;
  final bool showLatest;
  final ValueChanged<ExecutionDocument> onDocumentRequested;
  final VoidCallback onPreparing;
  final bool Function(ScrollNotification) onScroll;
  final VoidCallback onBackToLatest;
  final Future<void> Function(String) onCopyText;
  final ValueChanged<String> onSelectedTextChanged;
  final VoidCallback onCopySelection;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(18, 10, 18, 8),
          child: Wrap(
            spacing: 12,
            runSpacing: 6,
            children: [
              Text(
                strings.executionProcess,
                style: TextStyle(
                  color: colors.text,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                strings.executionProcessRecords(snapshot.records.length),
                style: TextStyle(color: colors.textMuted, fontSize: 12),
              ),
              if (snapshot.loading)
                Text(
                  strings.executionProcessLoading,
                  key: const Key('execution-process-loading'),
                  style: TextStyle(color: colors.textMuted, fontSize: 12),
                ),
            ],
          ),
        ),
        if (snapshot.error != null)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 120),
                    child: ExecutionViewerSelection(
                      onCopySelection: onCopySelection,
                      onSelectedTextChanged: onSelectedTextChanged,
                      child: SingleChildScrollView(
                        primary: false,
                        child: Text(
                          snapshot.error!,
                          key: const Key('execution-process-error'),
                          style: TextStyle(color: colors.warning, fontSize: 13),
                        ),
                      ),
                    ),
                  ),
                ),
                IconButton(
                  key: const Key('execution-process-copy-error'),
                  tooltip: strings.copyFailureReport,
                  onPressed: () => unawaited(onCopyText(snapshot.error!)),
                  icon: const Icon(Icons.copy_outlined, size: 16),
                ),
              ],
            ),
          ),
        Expanded(
          child: snapshot.records.isEmpty
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Text(
                      snapshot.loading
                          ? strings.executionProcessLoading
                          : strings.executionProcessEmpty,
                      textAlign: TextAlign.center,
                      style: TextStyle(color: colors.textMuted),
                    ),
                  ),
                )
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final textStyle = TextStyle(
                      inherit: false,
                      color: colors.text,
                      fontFamily: 'Geist Mono',
                      fontFamilyFallback: const ['Noto Sans SC', 'monospace'],
                      fontSize: 12.5,
                      height: 1.55,
                    );
                    final headerStyle = TextStyle(
                      inherit: false,
                      color: colors.textMuted,
                      fontFamily: 'Geist Sans',
                      fontFamilyFallback: const ['Noto Sans SC'],
                      fontSize: 12,
                      height: 1.4,
                      fontWeight: FontWeight.w600,
                    );
                    final width = math.max(1.0, constraints.maxWidth - 36);
                    final scaler = MediaQuery.textScalerOf(context);
                    final direction = Directionality.of(context);
                    final locale = Localizations.localeOf(context);
                    var requested = requestedDocument;
                    final expected = requested ?? document;
                    if (expected == null ||
                        expected.records != snapshot.records ||
                        expected.width != width ||
                        expected.textStyle != textStyle ||
                        expected.headerStyle != headerStyle ||
                        expected.textScaler != scaler ||
                        expected.direction != direction ||
                        expected.locale != locale) {
                      requested = ExecutionDocument(
                        records: snapshot.records,
                        width: width,
                        textStyle: textStyle,
                        headerStyle: headerStyle,
                        textScaler: scaler,
                        direction: direction,
                        locale: locale,
                        headerLabels: [
                          for (
                            var index = 0;
                            index < snapshot.records.length;
                            index++
                          )
                            [
                              if (snapshot.records[index].kind.isNotEmpty)
                                snapshot.records[index].kind
                              else
                                strings.executionProcessRecord(index + 1),
                              if (snapshot.records[index].timestamp.isNotEmpty)
                                snapshot.records[index].timestamp,
                            ].join(' · '),
                        ],
                      );
                      onDocumentRequested(requested);
                    }
                    final current = document;
                    if (current == null ||
                        (requested != null &&
                            !current.sameLayoutAs(requested))) {
                      onPreparing();
                      return Center(
                        child: Text(
                          strings.executionProcessPreparing,
                          key: const Key('execution-process-preparing'),
                          style: TextStyle(color: colors.textMuted),
                        ),
                      );
                    }
                    return ExecutionViewerRecords(
                      document: current,
                      scrollController: scrollController,
                      matches: matches,
                      matchIndex: matchIndex,
                      preparing: requested != null,
                      showLatest: showLatest,
                      onScroll: onScroll,
                      onBackToLatest: onBackToLatest,
                      onCopyText: onCopyText,
                      onSelectedTextChanged: onSelectedTextChanged,
                      onCopySelection: onCopySelection,
                    );
                  },
                ),
        ),
      ],
    );
  }
}
