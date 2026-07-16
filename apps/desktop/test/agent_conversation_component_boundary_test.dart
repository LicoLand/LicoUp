import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('conversation composer delegates bounded single-purpose components', () {
    const root = 'lib/src/application/features/agents/conversation';
    final componentFiles = [
      'conversation_session_state_controller.dart',
      'conversation_mobile_session_controller.dart',
      'conversation_session_controller.dart',
      'conversation_live_projection_controller.dart',
      'conversation_relay_projection_controller.dart',
      'conversation_message_controller.dart',
    ];
    final composer = File(
      '$root/agent_conversation_controller.dart',
    ).readAsStringSync();

    expect(composer.split('\n').length, lessThan(80));
    for (final fileName in componentFiles) {
      final source = File('$root/$fileName').readAsStringSync();
      expect(composer, contains(fileName));
      expect(source.split('\n').length, lessThan(800));
      expect(source, isNot(contains('client_controller.dart')));
      expect(
        source,
        isNot(contains(RegExp(r'^part(?: of)? ', multiLine: true))),
      );
    }
    final policy = File(
      '$root/conversation_runtime_result_policy.dart',
    ).readAsStringSync();
    final message = File(
      '$root/conversation_message_controller.dart',
    ).readAsStringSync();
    expect(policy.split('\n').length, lessThan(800));
    expect(policy, isNot(contains('client_controller.dart')));
    expect(message, contains('conversation_runtime_result_policy.dart'));

    expect(composer, isNot(contains('sendConversationMessage(String text)')));
    expect(
      composer,
      isNot(contains('loadConversationSessions(String agentId)')),
    );

    final rootController = File(
      'lib/src/application/controller/client_controller.dart',
    ).readAsStringSync();
    expect(rootController, contains('extends AgentOrchestrationController'));
    final orchestrationController = File(
      'lib/src/application/features/agents/orchestration/agent_orchestration_controller.dart',
    ).readAsStringSync();
    expect(
      orchestrationController,
      contains('extends AgentConversationController'),
    );
    expect(
      rootController,
      isNot(contains('with\n        AgentConversationController')),
    );
  });
}
