import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const root = 'lib/src/contracts';

  test('stable policy entrypoint contains exports only', () {
    final source = File(
      '$root/agent_orchestration_policy.dart',
    ).readAsStringSync();
    expect(
      source.split('\n').where((line) => line.trim().isNotEmpty),
      everyElement(startsWith('export ')),
    );
    expect(source, isNot(contains('class AgentOrchestrationPolicy')));
    expect(source, isNot(contains('normalizeAgentOrchestrationPolicy')));
  });

  test('policy leaves keep one independently testable responsibility', () {
    final models = _source(root, 'agent_orchestration_policy_models.dart');
    final codec = _source(root, 'agent_orchestration_policy_codec.dart');
    final catalog = _source(root, 'agent_orchestration_policy_catalog.dart');
    final validation = _source(
      root,
      'agent_orchestration_policy_validation.dart',
    );
    final merge = _source(root, 'agent_orchestration_policy_merge.dart');
    final target = _source(root, 'agent_orchestration_target.dart');

    expect(models, contains('final class AgentOrchestrationPolicy'));
    expect(models, isNot(contains('Map<String, dynamic> encode')));
    expect(codec, contains('final class AgentOrchestrationPolicyCodec'));
    expect(codec, isNot(contains('TargetCandidate')));
    expect(catalog, contains('agentOrchestrationModelLibraryCandidates'));
    expect(catalog, isNot(contains('normalizeAgentOrchestrationPolicy')));
    expect(validation, contains('normalizeAgentOrchestrationPolicy'));
    expect(validation, isNot(contains("'reasoningEfforts'")));
    expect(merge, contains('agentOrchestrationDispatchModelLibrary'));
    expect(merge, isNot(contains('TargetCandidate')));
    expect(target, contains('agentOrchestrationTargetCandidate'));
    expect(target, isNot(contains('AgentOrchestrationPolicy')));
  });
}

String _source(String root, String name) =>
    File('$root/$name').readAsStringSync();
