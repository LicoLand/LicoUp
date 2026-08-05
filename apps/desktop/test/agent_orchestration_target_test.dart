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

  test('daily conversation primary capsule projects to main_agent', () {
    const policy = AgentOrchestrationPolicy(
      dailyConversationAgents: [
        DailyConversationAgentAssignment(
          id: 'dc-1',
          agentId: 'cursor',
          modelName: 'composer-2',
          reasoningEffort: 'high',
        ),
        DailyConversationAgentAssignment(id: 'dc-2', agentId: 'codex'),
      ],
      commanderAgentId: 'codex',
      commanderModelName: 'gpt-5',
    );

    final synced = policy.withCommanderSyncedFromDailyConversation();
    expect(synced.commanderAgentId, 'cursor');
    expect(synced.commanderModelName, 'composer-2');
    expect(synced.commanderReasoningEffort, 'high');

    const legacy = AgentOrchestrationPolicy(
      commanderAgentId: 'codex',
      commanderModelName: 'gpt-5',
      commanderReasoningEffort: 'medium',
    );
    final seeded = legacy.withDailyConversationSeededFromCommander();
    expect(seeded.dailyConversationAgents, hasLength(1));
    expect(seeded.dailyConversationAgents.single.agentId, 'codex');
    expect(seeded.dailyConversationAgents.single.modelName, 'gpt-5');
  });

  test(
    'dailyConversationMatchForCurrentConversation prefers agent+model',
    () {
      const policy = AgentOrchestrationPolicy(
        dailyConversationAgents: [
          DailyConversationAgentAssignment(
            id: 'dc-1',
            agentId: 'antigravity',
            modelName: 'gemini-3-flash',
            fast: false,
          ),
          DailyConversationAgentAssignment(
            id: 'dc-2',
            agentId: 'antigravity',
            modelName: 'claude-opus-4-6-thinking',
            reasoningEffort: 'high',
            fast: true,
          ),
        ],
        commanderAgentId: 'antigravity',
        commanderModelName: 'claude-opus-4-6-thinking',
      );

      final match = policy.dailyConversationMatchForCurrentConversation();
      expect(match?.id, 'dc-2');
      expect(match?.fast, isTrue);
    },
  );

  test(
    'normalize keeps Current Conversation when it differs from Daily primary',
    () {
      const policy = AgentOrchestrationPolicy(
        dailyConversationAgents: [
          DailyConversationAgentAssignment(
            id: 'dc-1',
            agentId: 'cursor',
            modelName: 'composer-2',
          ),
          DailyConversationAgentAssignment(
            id: 'dc-2',
            agentId: 'codex',
            modelName: 'gpt-5',
          ),
        ],
        commanderAgentId: 'codex',
        commanderModelName: 'gpt-5',
        commanderReasoningEffort: 'high',
      );

      final normalized = normalizeOrchestrationPolicyForPersistence(policy);
      expect(normalized.dailyConversationAgentIds.first, 'cursor');
      expect(normalized.commanderAgentId, 'codex');
      expect(normalized.commanderModelName, 'gpt-5');
      expect(normalized.commanderReasoningEffort, 'high');
    },
  );

  test(
    'normalize fills empty Current Conversation from Daily primary',
    () {
      const policy = AgentOrchestrationPolicy(
        dailyConversationAgents: [
          DailyConversationAgentAssignment(
            id: 'dc-1',
            agentId: 'cursor',
            modelName: 'composer-2',
            reasoningEffort: 'medium',
          ),
        ],
      );

      final normalized = normalizeOrchestrationPolicyForPersistence(policy);
      expect(normalized.commanderAgentId, 'cursor');
      expect(normalized.commanderModelName, 'composer-2');
      expect(normalized.commanderReasoningEffort, 'medium');
    },
  );

  test(
    'normalize fills blank Current Conversation model from Daily match',
    () {
      const policy = AgentOrchestrationPolicy(
        dailyConversationAgents: [
          DailyConversationAgentAssignment(
            id: 'dc-1',
            agentId: 'antigravity',
            modelName: 'claude-opus-4-6-thinking',
            reasoningEffort: 'high',
            fast: true,
          ),
        ],
        commanderAgentId: 'antigravity',
      );

      final normalized = normalizeOrchestrationPolicyForPersistence(policy);
      expect(normalized.commanderAgentId, 'antigravity');
      expect(normalized.commanderModelName, 'claude-opus-4-6-thinking');
      expect(normalized.commanderReasoningEffort, 'high');
    },
  );

  test('code engineering persists one Designer and lane-specific roles', () {
    const assignment = AgentOrchestrationRoleAssignment(
      agentId: 'codex',
      modelName: 'gpt-5',
      reasoningEffort: 'high',
    );
    const policy = AgentOrchestrationPolicy(
      dailyConversationAgents: [
        DailyConversationAgentAssignment(
          id: 'dc-1',
          agentId: 'codex',
          modelName: 'gpt-5',
          reasoningEffort: 'high',
          fast: true,
        ),
        DailyConversationAgentAssignment(
          id: 'dc-2',
          agentId: 'codex',
          modelName: 'gpt-5',
          reasoningEffort: 'medium',
        ),
        DailyConversationAgentAssignment(id: 'dc-3', agentId: 'cursor'),
      ],
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
    final dailyConversation = encoded['daily_conversation'] as Map;
    final dailyAgents = dailyConversation['agents'] as List;

    expect(dailyAgents, hasLength(3));
    expect(dailyAgents.first, {
      'id': 'dc-1',
      'agent': 'codex',
      'model': 'gpt-5',
      'reasoning_effort': 'high',
      'fast': true,
    });
    expect(decoded.dailyConversationAgents, hasLength(3));
    expect(decoded.dailyConversationAgentIds, ['codex', 'cursor']);
    expect(decoded.dailyConversationAgents.first.fast, isTrue);
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
