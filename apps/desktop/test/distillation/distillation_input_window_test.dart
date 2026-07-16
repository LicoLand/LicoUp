import 'dart:convert';

import 'package:flutter_client/src/contracts/routing/distillation/distillation_input_window.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('semantic pins and newest turns stay inside every hard limit', () {
    final source = <DistillationConversationTurn>[
      const DistillationConversationTurn(
        role: 'user',
        text: 'Objective: preserve the original routing objective marker.',
      ),
      const DistillationConversationTurn(
        role: 'assistant',
        text: 'Decision: preserve the declarative policy decision marker.',
      ),
      const DistillationConversationTurn(
        role: 'user',
        text: 'Constraint: preserve the privacy constraint marker.',
      ),
      for (var index = 0; index < 100; index++)
        DistillationConversationTurn(
          role: 'assistant',
          text: 'recent progress turn $index ${List.filled(1024, 'x').join()}',
        ),
    ];

    final window = buildDistillationInputWindow(source);
    final text = window.turns.map((turn) => turn.text).join('\n');
    expect(window.turns.length, lessThanOrEqualTo(48));
    expect(window.byteCount, lessThanOrEqualTo(64 * 1024));
    expect(window.approxTokenCount, lessThanOrEqualTo(12 * 1024));
    expect(text, contains('routing objective marker'));
    expect(text, contains('policy decision marker'));
    expect(text, contains('privacy constraint marker'));
    expect(text, contains('recent progress turn 99'));
    expect(window.truncated, isTrue);
  });

  test('each compacted turn respects the 8 KiB UTF-8 limit', () {
    final window = buildDistillationInputWindow([
      DistillationConversationTurn(
        role: 'user',
        text: List.filled(4096, '你').join(),
      ),
    ]);

    expect(window.turns, hasLength(1));
    expect(
      utf8.encode(window.turns.single.text).length,
      lessThanOrEqualTo(distillationInputMaxTurnBytes),
    );
    expect(approximateDistillationTokens('abcd你'), 2);
  });
}
