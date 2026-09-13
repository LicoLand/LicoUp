import 'dart:math' as math;

import 'package:flutter/painting.dart';

import 'conversation_execution_models.dart';

/// Bounded text paragraphs keep one very large tool result from creating a
/// single enormous render object. Ranges always address the original string;
/// copying and searching never split/rejoin or normalize it.
class ExecutionTextChunk {
  const ExecutionTextChunk(this.start, this.end);

  final int start;
  final int end;
}

List<ExecutionTextChunk> executionTextChunks(String rawText) {
  if (rawText.isEmpty) return const [ExecutionTextChunk(0, 0)];
  final chunks = <ExecutionTextChunk>[];
  var start = 0;
  while (start < rawText.length) {
    var end = math.min(start + 4096, rawText.length);
    var lastLineEnd = start;
    var lines = 0;
    // Search only inside this chunk. Searching the entire remaining string
    // for a newline makes a large single-line result quadratic to partition.
    for (var cursor = start; cursor < end; cursor++) {
      if (rawText.codeUnitAt(cursor) == 10) {
        lastLineEnd = cursor + 1;
        if (++lines == 48) {
          end = lastLineEnd;
          break;
        }
      }
    }
    if (end < rawText.length) {
      if (lastLineEnd > start) {
        end = lastLineEnd;
      } else {
        // Never separate a UTF-16 surrogate pair or a CRLF delimiter.
        final previous = rawText.codeUnitAt(end - 1);
        if ((previous >= 0xd800 && previous <= 0xdbff) ||
            (previous == 13 && rawText.codeUnitAt(end) == 10)) {
          end -= 1;
        }
      }
    }
    chunks.add(ExecutionTextChunk(start, end));
    start = end;
  }
  return chunks;
}

class ExecutionSearchMatch {
  const ExecutionSearchMatch(this.recordIndex, this.start, this.end);

  final int recordIndex;
  final int start;
  final int end;
}

List<ExecutionSearchMatch> searchExecutionRecords(
  List<ConversationExecutionRecord> records,
  String query,
) {
  if (query.isEmpty) return const [];
  final pattern = RegExp(RegExp.escape(query), caseSensitive: false);
  return [
    for (var index = 0; index < records.length; index++)
      for (final match in pattern.allMatches(records[index].rawText))
        ExecutionSearchMatch(index, match.start, match.end),
  ];
}

class ExecutionDocumentRow {
  const ExecutionDocumentRow({
    required this.recordIndex,
    required this.offset,
    required this.height,
    this.chunk,
  });

  final int recordIndex;
  final double offset;
  final double height;
  final ExecutionTextChunk? chunk;
  bool get isHeader => chunk == null;
}

class ExecutionDocumentAnchor {
  const ExecutionDocumentAnchor({
    required this.recordId,
    required this.recordIndex,
    required this.textOffset,
    required this.withinLineOffset,
  });

  final String recordId;
  final int recordIndex;
  final int? textOffset;
  final double withinLineOffset;
}

/// TextPainter uses exactly the same constraints and styles as the visible
/// paragraphs. [prepare] yields between short batches, then publishes exact
/// extents together. No estimated heights can move an already-visible row.
class ExecutionDocument {
  ExecutionDocument({
    required this.records,
    required this.width,
    required this.textStyle,
    required this.headerStyle,
    required this.textScaler,
    required this.direction,
    required this.locale,
    required this.headerLabels,
  });

  bool sameLayoutAs(ExecutionDocument other) =>
      width == other.width &&
      textStyle == other.textStyle &&
      headerStyle == other.headerStyle &&
      textScaler == other.textScaler &&
      direction == other.direction &&
      locale == other.locale;

  /// Prepares this document once. A superseded request returns false after
  /// yielding; it never starts a second concurrent layout task. [yieldToUi]
  /// allows deterministic scheduling in synthetic tests and measurements.
  Future<bool> prepare({
    ExecutionDocument? previous,
    required bool Function() isCurrent,
    Future<void> Function()? yieldToUi,
  }) async {
    final reusable =
        previous != null &&
        previous.width == width &&
        previous.textStyle == textStyle &&
        previous.headerStyle == headerStyle &&
        previous.textScaler == textScaler &&
        previous.direction == direction &&
        previous.locale == locale;
    var offset = 0.0;
    var measuredInBatch = 0;
    for (var recordIndex = 0; recordIndex < records.length; recordIndex++) {
      if (!isCurrent()) return false;
      final record = records[recordIndex];
      final old = reusable && recordIndex < previous.records.length
          ? previous.records[recordIndex]
          : null;
      final reuse =
          old?.id == record.id &&
          old?.rawText == record.rawText &&
          previous!.headerLabels[recordIndex] == headerLabels[recordIndex];
      final measurements = reuse
          ? previous._measurements[recordIndex]
          : <({ExecutionTextChunk? chunk, double height})>[];
      _measurements.add(measurements);
      recordFirstRows.add(rows.length);
      final pending = reuse
          ? measurements
          : _measureRecord(record, headerLabels[recordIndex]);
      for (final measurement in pending) {
        if (!reuse) measurements.add(measurement);
        rows.add(
          ExecutionDocumentRow(
            recordIndex: recordIndex,
            offset: offset,
            height: measurement.height,
            chunk: measurement.chunk,
          ),
        );
        offset += measurement.height;
        if (!reuse && ++measuredInBatch == 8) {
          measuredInBatch = 0;
          // This schedules more layout work; it is not an execution timeout.
          await (yieldToUi?.call() ?? Future<void>.delayed(Duration.zero));
          if (!isCurrent()) return false;
        }
      }
    }
    totalHeight = offset;
    return true;
  }

  final List<ConversationExecutionRecord> records;
  final double width;
  final TextStyle textStyle;
  final TextStyle headerStyle;
  final TextScaler textScaler;
  final TextDirection direction;
  final Locale locale;
  final List<String> headerLabels;
  final rows = <ExecutionDocumentRow>[];
  final recordFirstRows = <int>[];
  final _measurements = <List<({ExecutionTextChunk? chunk, double height})>>[];
  late final double totalHeight;

  TextPainter painter(String text, TextStyle style, double maxWidth) =>
      TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: direction,
        textScaler: textScaler,
        locale: locale,
      )..layout(maxWidth: maxWidth);

  Iterable<({ExecutionTextChunk? chunk, double height})> _measureRecord(
    ConversationExecutionRecord record,
    String label,
  ) sync* {
    final heading = painter(label, headerStyle, math.max(1, width - 64));
    final headerHeight = math.max(40, heading.height + 8);
    heading.dispose();
    yield (chunk: null, height: headerHeight + 24);
    final chunks = executionTextChunks(record.rawText);
    for (var index = 0; index < chunks.length; index++) {
      final chunk = chunks[index];
      final text = record.rawText.substring(chunk.start, chunk.end);
      final paragraph = painter(text, textStyle, width);
      var height = paragraph.height;
      if (index < chunks.length - 1 && text.endsWith('\n')) {
        // The next paragraph supplies the empty final line after this newline.
        // The raw substring itself remains untouched in the renderer.
        height -= paragraph.computeLineMetrics().last.height;
      }
      paragraph.dispose();
      yield (
        chunk: chunk,
        height: height + (index == chunks.length - 1 ? 20 : 0),
      );
    }
  }

  double offsetForMatch(ExecutionSearchMatch match) {
    var rowIndex = recordFirstRows[match.recordIndex] + 1;
    while (rowIndex + 1 < rows.length &&
        rows[rowIndex + 1].recordIndex == match.recordIndex &&
        rows[rowIndex].chunk!.end <= match.start) {
      rowIndex += 1;
    }
    final row = rows[rowIndex];
    final chunk = row.chunk!;
    final paragraph = painter(
      records[match.recordIndex].rawText.substring(chunk.start, chunk.end),
      textStyle,
      width,
    );
    final caret = paragraph.getOffsetForCaret(
      TextPosition(offset: match.start - chunk.start),
      Rect.zero,
    );
    paragraph.dispose();
    return row.offset + caret.dy;
  }

  ExecutionDocumentAnchor anchorAtOffset(double offset) {
    var low = 0;
    var high = rows.length;
    while (low + 1 < high) {
      final middle = (low + high) ~/ 2;
      if (rows[middle].offset <= offset) {
        low = middle;
      } else {
        high = middle;
      }
    }
    final row = rows[low];
    final record = records[row.recordIndex];
    final chunk = row.chunk;
    if (chunk == null) {
      return ExecutionDocumentAnchor(
        recordId: record.id,
        recordIndex: row.recordIndex,
        textOffset: null,
        withinLineOffset: offset - row.offset,
      );
    }
    final paragraph = painter(
      record.rawText.substring(chunk.start, chunk.end),
      textStyle,
      width,
    );
    final position = paragraph.getPositionForOffset(
      Offset(0, math.max(0, offset - row.offset)),
    );
    final caret = paragraph.getOffsetForCaret(position, Rect.zero);
    paragraph.dispose();
    return ExecutionDocumentAnchor(
      recordId: record.id,
      recordIndex: row.recordIndex,
      textOffset: chunk.start + position.offset,
      withinLineOffset: offset - row.offset - caret.dy,
    );
  }

  double? offsetForAnchor(ExecutionDocumentAnchor anchor) {
    final index =
        anchor.recordIndex < records.length &&
            records[anchor.recordIndex].id == anchor.recordId
        ? anchor.recordIndex
        : records.indexWhere((record) => record.id == anchor.recordId);
    if (index < 0) return null;
    final textOffset = anchor.textOffset;
    if (textOffset == null) {
      final row = rows[recordFirstRows[index]];
      return row.offset + math.min(anchor.withinLineOffset, row.height);
    }
    final offset = math.min(textOffset, records[index].rawText.length);
    return offsetForMatch(ExecutionSearchMatch(index, offset, offset)) +
        anchor.withinLineOffset;
  }
}
