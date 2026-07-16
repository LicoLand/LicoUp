import 'dart:io';

import 'package:flutter_client/src/application/features/agents/orchestration/agent_orchestration_dispatch_models.dart';
import 'package:flutter_client/src/application/features/agents/orchestration/agent_orchestration_presentation.dart';
import 'package:flutter_client/src/contracts/routing/routing_dispatch_plan.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('orchestration composer delegates bounded lifecycle components', () {
    const root = 'lib/src/application/features/agents/orchestration';
    const components = [
      'agent_orchestration_policy_controller.dart',
      'agent_orchestration_presentation.dart',
      'agent_orchestration_conversation_controller.dart',
      'agent_orchestration_routing_boundary_controller.dart',
      'agent_orchestration_dispatch_controller.dart',
    ];
    final composer = File(
      '$root/agent_orchestration_controller.dart',
    ).readAsStringSync();
    expect(composer.split('\n').length, lessThan(80));
    for (final fileName in components) {
      final source = File('$root/$fileName').readAsStringSync();
      expect(composer, contains(fileName));
      expect(source.split('\n').length, lessThan(800));
      expect(source, isNot(contains('client_controller.dart')));
      expect(
        source,
        isNot(contains(RegExp(r'^part(?: of)? ', multiLine: true))),
      );
    }
    final models = File(
      '$root/agent_orchestration_dispatch_models.dart',
    ).readAsStringSync();
    final dispatch = File(
      '$root/agent_orchestration_dispatch_controller.dart',
    ).readAsStringSync();
    expect(models.split('\n').length, lessThan(200));
    expect(dispatch, contains('agent_orchestration_dispatch_models.dart'));
    expect(
      composer,
      isNot(contains('sendOrchestratedConversationMessage(String text)')),
    );

    final rootController = File(
      'lib/src/application/controller/client_controller.dart',
    ).readAsStringSync();
    expect(rootController, contains('extends AgentOrchestrationController'));
    expect(
      rootController,
      isNot(contains('with\n        AgentOrchestrationController')),
    );
  });

  test('dispatch result and bounded text are independent pure contracts', () {
    const route = RoutingDispatchRoute(
      agentId: 'codex',
      agentLabel: 'Codex',
      role: 'primary',
      modelName: '',
      reasoningEffort: '',
      priority: 1,
      coordinator: true,
      reason: 'test',
    );
    const outcome = OrchestrationDispatchOutcome(
      route: route,
      ok: true,
      status: 'replied',
      replyText: 'done',
    );
    expect(outcome.route.agentId, 'codex');
    expect(outcome.replyText, 'done');
    expect(truncateOrchestrationText('你好世界', 2), '你好');
  });
}
