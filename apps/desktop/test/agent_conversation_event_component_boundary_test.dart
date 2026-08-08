import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('event card barrel separates timeline projection and process UI', () {
    final root = File(
      'lib/src/frontend/features/agents/ui/agent_conversation_event_card.dart',
    ).readAsStringSync();
    final timeline = File(
      'lib/src/frontend/features/agents/ui/agent_conversation_timeline.dart',
    ).readAsStringSync();
    final projection = File(
      'lib/src/frontend/features/agents/ui/agent_conversation_process_projection.dart',
    ).readAsStringSync();
    expect(root, isNot(contains('class ConversationProcessCard')));
    expect(timeline, isNot(contains("package:flutter/material.dart")));
    expect(projection, isNot(contains("package:flutter/material.dart")));
  });
}
