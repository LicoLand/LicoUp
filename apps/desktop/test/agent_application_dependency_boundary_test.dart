import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('agent feature controllers depend on ports, not composition roots', () {
    final directory = Directory('lib/src/application/features/agents');
    final sources = directory
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'));

    for (final file in sources) {
      final source = file.readAsStringSync();
      final applicationSource = source.replaceAll(
        "import 'package:licoup/src/platform/native_client/orchestrator_ipc/client.dart';",
        '',
      );
      expect(
        source,
        isNot(contains('/application/controller/client_controller.dart')),
        reason: file.path,
      );
      expect(source, isNot(contains('/backend/')), reason: file.path);
      expect(
        applicationSource,
        isNot(contains('/platform/')),
        reason: file.path,
      );
      expect(
        source,
        isNot(contains('TextEditingController')),
        reason: file.path,
      );
      expect(
        source,
        isNot(contains(RegExp(r'^\s*part(?:\s+of)?\s+', multiLine: true))),
        reason: file.path,
      );
    }
  });

  test('agent modules expose controllers backed by narrow gateway ports', () {
    final conversation = File(
      'lib/src/application/features/agents/conversation/agent_conversation_controller.dart',
    ).readAsStringSync();
    final conversationSessions = File(
      'lib/src/application/features/agents/conversation/conversation_session_controller.dart',
    ).readAsStringSync();
    final usage = File(
      'lib/src/application/features/agents/controller/agent_usage_controller.dart',
    ).readAsStringSync();
    final orchestration = File(
      'lib/src/application/features/agents/orchestration/agent_orchestration_controller.dart',
    ).readAsStringSync();
    final workspace = File(
      'lib/src/application/features/agents/workspace/agent_workspace_coordinator.dart',
    ).readAsStringSync();

    expect(conversation, contains('AgentConversationSessionController'));
    expect(
      conversationSessions,
      contains('conversationGateway.streamSessions'),
    );
    expect(
      workspace,
      contains('AgentConversationGateway get conversationGateway'),
    );
    expect(usage, contains('AgentUsageGateway'));
    expect(usage, contains('acquirePollingOwner'));
    expect(orchestration, contains('extends AgentConversationController'));
  });
}
