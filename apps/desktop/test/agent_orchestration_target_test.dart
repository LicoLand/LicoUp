import 'package:licoup/src/application/features/agents/orchestration/orchestration_policy_editor_models.dart';
import 'package:licoup/src/contracts/agent_orchestration_target.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'virtual orchestration target is local and never aliases real agents',
    () {
      final target = agentOrchestrationTargetCandidate(label: 'Default');

      expect(
        isAgentOrchestrationTargetId(' $agentOrchestrationTargetId '),
        isTrue,
      );
      expect(isAgentOrchestrationTargetId('codex'), isFalse);
      expect(target.target, agentOrchestrationTargetId);
      expect(target.kind, 'multi-agent-orchestration');
      expect(target.scanSource, 'local-ui');
      expect(target.adapterCapabilities['virtual'], isTrue);
    },
  );

  test('main-agent selection does not require a discovered model catalog', () {
    final target = TargetCandidate(
      target: 'codex',
      label: 'Codex',
      kind: 'cli',
      status: 'detected',
      configured: true,
      confidence: 1,
      binaryPath: '/synthetic/bin/codex',
      adapterStatus: 'implemented',
      adapterCapabilities: const {'conversationDriver': 'implemented'},
    );

    final policy = sanitizeOrchestrationPolicyEditorDraft([
      target,
    ], const AgentOrchestrationPolicy(commanderAgentId: 'codex'));

    expect(policy.configured, isTrue);
    expect(policy.commanderAgentId, 'codex');
    expect(policy.commanderModelName, isEmpty);
    expect((policy.toTomlConfig()['main_agent'] as Map)['agent'], 'codex');
  });

  test('code engineering persists one Designer and lane-specific roles', () {
    const assignment = AgentOrchestrationRoleAssignment(
      agentId: 'codex',
      modelName: 'gpt-5',
      reasoningEffort: 'high',
    );
    const policy = AgentOrchestrationPolicy(
      commanderAgentId: 'codex',
      codeEngineeringRoles: {
        CodeEngineeringRoleSlot.designer: assignment,
        CodeEngineeringRoleSlot.backendWorker: assignment,
        CodeEngineeringRoleSlot.frontendWorker: assignment,
        CodeEngineeringRoleSlot.backendReviewer: assignment,
        CodeEngineeringRoleSlot.frontendReviewer: assignment,
      },
    );

    final encoded = policy.toTomlConfig();
    final decoded = AgentOrchestrationPolicy.fromTomlConfig(encoded);
    final codeEngineering = encoded['code_engineering'] as Map;

    expect(codeEngineering['strategy'], 'frontend_backend_roles');
    expect((codeEngineering['worker'] as Map).keys.toSet(), {
      'backend',
      'frontend',
    });
    expect((codeEngineering['reviewer'] as Map).keys.toSet(), {
      'backend',
      'frontend',
    });
    expect(decoded.codeEngineeringConfigured, isTrue);
    expect(
      decoded.assignmentFor(CodeEngineeringRoleSlot.frontendReviewer),
      isA<AgentOrchestrationRoleAssignment>()
          .having((value) => value.agentId, 'agentId', 'codex')
          .having((value) => value.modelName, 'modelName', 'gpt-5')
          .having((value) => value.reasoningEffort, 'reasoningEffort', 'high'),
    );
  });
}
