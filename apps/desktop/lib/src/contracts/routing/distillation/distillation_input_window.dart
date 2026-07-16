import 'dart:convert';

import 'package:flutter/foundation.dart';

import 'distillation_semantics.dart';
import 'distillation_utf8.dart';

@immutable
class DistillationConversationTurn {
  const DistillationConversationTurn({required this.role, required this.text});

  final String role;
  final String text;
}

/// Hard limits for one dispatch. Tokens are conservatively approximated as
/// one non-ASCII rune or four ASCII bytes.
const int distillationInputMaxTurns = 48;
const int distillationInputMaxBytes = 64 * 1024;
const int distillationInputMaxApproxTokens = 12 * 1024;
const int distillationInputMaxTurnBytes = 8 * 1024;

@immutable
class DistillationInputWindow {
  const DistillationInputWindow({
    required this.turns,
    required this.byteCount,
    required this.approxTokenCount,
    required this.sourceTurnCount,
  });

  final List<DistillationConversationTurn> turns;
  final int byteCount;
  final int approxTokenCount;
  final int sourceTurnCount;

  bool get truncated => turns.length < sourceTurnCount;
}

/// Pins the newest preservation-class turns, then fills newest-first in O(n).
DistillationInputWindow buildDistillationInputWindow(
  List<DistillationConversationTurn> source, {
  Set<String> preserveFields = const {'objective', 'decisions', 'constraints'},
  int maxTurns = distillationInputMaxTurns,
  int maxBytes = distillationInputMaxBytes,
  int maxApproxTokens = distillationInputMaxApproxTokens,
}) {
  final turnLimit = maxTurns.clamp(1, distillationInputMaxTurns);
  final byteLimit = maxBytes.clamp(1, distillationInputMaxBytes);
  final tokenLimit = maxApproxTokens.clamp(1, distillationInputMaxApproxTokens);
  final compact = <DistillationConversationTurn>[];
  for (final turn in source) {
    final text = truncateDistillationUtf8(
      turn.text.trim(),
      distillationInputMaxTurnBytes,
    );
    if (text.isNotEmpty) {
      compact.add(
        DistillationConversationTurn(role: turn.role.trim(), text: text),
      );
    }
  }

  final pinnedByField = <String, int>{};
  for (final field in preserveFields) {
    for (var index = compact.length - 1; index >= 0; index--) {
      if (distillationSemanticSections(compact[index].text).contains(field)) {
        pinnedByField[field] = index;
        break;
      }
    }
  }

  final selected = <int>{};
  var bytes = 0;
  var tokens = 0;
  bool addIndex(int index) {
    if (selected.contains(index) || selected.length >= turnLimit) {
      return false;
    }
    final turn = compact[index];
    final turnBytes = utf8.encode('${turn.role}:${turn.text}\n').length;
    final turnTokens = approximateDistillationTokens(turn.text);
    if (bytes + turnBytes > byteLimit || tokens + turnTokens > tokenLimit) {
      return false;
    }
    selected.add(index);
    bytes += turnBytes;
    tokens += turnTokens;
    return true;
  }

  for (final field in const ['objective', 'decisions', 'constraints']) {
    final index = pinnedByField[field];
    if (index != null) {
      addIndex(index);
    }
  }
  final remainingPins =
      pinnedByField.entries
          .where(
            (entry) =>
                entry.key != 'objective' &&
                entry.key != 'decisions' &&
                entry.key != 'constraints',
          )
          .map((entry) => entry.value)
          .toSet()
          .toList()
        ..sort((a, b) => b.compareTo(a));
  for (final index in remainingPins) {
    addIndex(index);
  }
  for (var index = compact.length - 1; index >= 0; index--) {
    addIndex(index);
  }

  final ordered = selected.toList()..sort();
  return DistillationInputWindow(
    turns: List.unmodifiable([for (final index in ordered) compact[index]]),
    byteCount: bytes,
    approxTokenCount: tokens,
    sourceTurnCount: source.length,
  );
}

int approximateDistillationTokens(String text) {
  var asciiBytes = 0;
  var nonAsciiRunes = 0;
  for (final rune in text.runes) {
    if (rune <= 0x7f) {
      asciiBytes += 1;
    } else {
      nonAsciiRunes += 1;
    }
  }
  return ((asciiBytes + 3) ~/ 4) + nonAsciiRunes;
}
