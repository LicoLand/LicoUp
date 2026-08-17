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
  test('Claude family aliases are not required from the catalog helper', () {
    final target = _target(
      id: 'claude-code',
      models: const [
        {'name': 'claude-opus-4-6', 'displayName': 'Claude Opus 4.6'},
        {'name': 'claude-sonnet-4-6', 'displayName': 'Claude Sonnet 4.6'},
      ],
    );
    expect(agentOrchestrationCommanderModels(target), [
      'claude-opus-4-6',
      'claude-sonnet-4-6',
    ]);
    expect(agentOrchestrationCommanderModels(target), isNot(contains('opus')));
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

  test('OpenCode provider-qualified models stay selectable', () {
    final target = _target(
      id: 'opencode',
      models: const [
        {
          'name': 'anthropic/claude-sonnet-4-5',
          'displayName': 'Claude Sonnet 4.5',
          'providerId': 'anthropic',
        },
      ],
    );
    expect(agentOrchestrationCommanderModels(target), [
      'anthropic/claude-sonnet-4-5',
    ]);
  });
}
