import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/application/features/agents/adaptive_flywheel/adaptive_flywheel_target_catalog.dart';
import 'package:licoup/src/contracts/target_candidate.dart';

TargetCandidate _target({
  required String id,
  required List<Map<String, dynamic>> models,
}) {
  return TargetCandidate(
    target: id,
    label: id,
    kind: 'cli',
    status: 'detected',
    configured: true,
    confidence: 1,
    binaryPath: '/synthetic/bin/$id',
    adapterStatus: 'implemented',
    adapterCapabilities: const {'conversationDriver': 'implemented'},
    modelCatalog: {'models': models},
  );
}

void main() {
  test('Assistant catalog includes detected Codex and DeepSeek Harness', () {
    final targets = agentOrchestrationCommanderTargets([
      _target(id: 'codex', models: const []),
      _target(id: 'deepseek-harness', models: const []),
    ]);

    expect(targets.map((target) => target.target), [
      'codex',
      'deepseek-harness',
    ]);
  });

  test('Claude Code exposes the configured current model unchanged', () {
    final target = _target(
      id: 'claude-code',
      models: const [
        {
          'name': 'deepseek-v4-flash',
          'displayName': 'DeepSeek V4 Flash',
          'providerId': 'deepseek',
          'provider': 'DeepSeek',
        },
      ],
    );
    expect(agentOrchestrationCommanderModels(target), ['deepseek-v4-flash']);
    expect(
      agentOrchestrationModelDisplayName(target, 'deepseek-v4-flash'),
      'DeepSeek V4 Flash',
    );
  });

  test('empty effort catalogs omit the independent reasoning dimension', () {
    final cursor = _target(
      id: 'cursor',
      models: const [
        {
          'name': 'fable-5-1m-medium',
          'displayName': 'Fable 5 1M Medium',
          'reasoningEfforts': <String>[],
        },
      ],
    );
    expect(
      agentOrchestrationReasoningEffortsForModel(cursor, 'fable-5-1m-medium'),
      isEmpty,
    );
    expect(agentOrchestrationReasoningEffortsFor(cursor), isEmpty);
    expect(
      agentOrchestrationDefaultReasoningEffortForModel(
        cursor,
        'fable-5-1m-medium',
      ),
      isEmpty,
    );
  });

  test('models are grouped by catalog provider metadata', () {
    final target = _target(
      id: 'opencode',
      models: const [
        {
          'name': 'opaque-one/model-a',
          'displayName': 'Model A',
          'providerId': 'opaque-one',
          'provider': 'Provider One',
        },
        {
          'name': 'opaque-two/model-b',
          'displayName': 'Model B',
          'providerId': 'opaque-two',
          'provider': 'Provider Two',
        },
        {
          'name': 'opaque-one/model-c',
          'displayName': 'Model C',
          'providerId': 'opaque-one',
          'provider': 'Provider One',
        },
      ],
    );

    final groups = agentOrchestrationCommanderModelGroups(target);
    expect(groups, hasLength(2));
    expect(groups[0].providerId, 'opaque-one');
    expect(groups[0].providerLabel, 'Provider One');
    expect(groups[0].models, ['opaque-one/model-a', 'opaque-one/model-c']);
    expect(groups[1].providerId, 'opaque-two');
    expect(groups[1].providerLabel, 'Provider Two');
    expect(groups[1].models, ['opaque-two/model-b']);
  });
}
