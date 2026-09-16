import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'flutter_adapter.dart';
import 'model.dart';

void main() {
  testWidgets(
    'scroll accepts a visible endpoint but rejects stationary interior messages',
    (tester) async {
      final machine = UiInteractionModel.load().machines.singleWhere(
        (machine) => machine.id == 'dashboard.conversation-journey',
      );
      final adapter = FlutterInteractionAdapter(
        tester,
        machine,
        nativeAgentId: 'fixture',
      );
      // Stationary content isolates the endpoint rule from elastic overscroll.
      // RichText renders these labels without a trailing newline.
      for (final (label, action, endpoint) in [
        ('Canonical message 1', 'conversation.scroll-up', true),
        ('Canonical message 65', 'conversation.scroll-down', true),
        ('Canonical message 11', 'conversation.scroll-up', false),
        ('Canonical message 64', 'conversation.scroll-down', false),
      ]) {
        await tester.pumpWidget(
          MaterialApp(
            home: SizedBox(
              key: const Key('canonical-group-conversation-pane'),
              child: ListView(
                physics: const NeverScrollableScrollPhysics(),
                children: [Text(label)],
              ),
            ),
          ),
        );
        if (endpoint) {
          await adapter.act(action);
        } else {
          Object? failure;
          try {
            await adapter.act(action);
          } catch (error) {
            failure = error;
          }
          expect(failure, isA<TestFailure>());
        }
      }
    },
  );
}
