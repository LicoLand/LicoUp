import 'package:flutter/foundation.dart';

import 'package:licoup/src/contracts/conversation_execution.dart';

export 'package:licoup/src/contracts/conversation_execution.dart'
    show ConversationExecutionRecord;

/// The owner supplies every available record in original oldest-first order
/// and publishes replacements/appends while the viewer is open. This view
/// contains no execution state, persistence or data-loading behavior.
@immutable
class ConversationExecutionSnapshot {
  const ConversationExecutionSnapshot({
    this.records = const [],
    this.loading = false,
    this.error,
  });

  final List<ConversationExecutionRecord> records;
  final bool loading;
  final String? error;
}

/// An append preserves the exact prefix already being laid out. Rewritten
/// records require a new layout generation instead of reusing stale extents.
bool executionRecordsExtend(
  List<ConversationExecutionRecord> prefix,
  List<ConversationExecutionRecord> records,
) {
  if (records.length < prefix.length) return false;
  for (var index = 0; index < prefix.length; index++) {
    final before = prefix[index];
    final after = records[index];
    if (identical(before, after)) continue;
    if (before.id != after.id ||
        before.rawText != after.rawText ||
        before.kind != after.kind ||
        before.timestamp != after.timestamp) {
      return false;
    }
  }
  return true;
}
