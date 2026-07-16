import 'dart:convert';
import 'dart:io';

import 'package:flutter_client/src/contracts/routing/distillation_package.dart';
import 'package:flutter_client/src/contracts/routing/routing_policy_schema.dart';

class DistillationBrokerHarness {
  const DistillationBrokerHarness({required this.policy, required this.turns});

  factory DistillationBrokerHarness.load() {
    final source = File(
      'test/fixtures/routing/distill-policy.json',
    ).readAsStringSync();
    final parsed = parseRoutingPolicyDocument(source);
    if (parsed is! RoutingPolicyParseSuccess) {
      throw StateError('Distillation policy fixture must remain valid.');
    }
    return DistillationBrokerHarness(
      policy: parsed.document,
      turns: fixtureTurns,
    );
  }

  final RoutingPolicyDocument policy;
  final List<DistillationConversationTurn> turns;

  static const fixtureTurns = [
    DistillationConversationTurn(
      role: 'user',
      text: 'Goal: ship the routing module with hot reload.',
    ),
    DistillationConversationTurn(
      role: 'assistant',
      text: 'Current state: policy schema landed; broker in progress.',
    ),
    DistillationConversationTurn(
      role: 'assistant',
      text:
          'Decision: use declarative policy files as the sole metadata authority.',
    ),
    DistillationConversationTurn(
      role: 'user',
      text:
          'Constraint: must not store raw conversation text in audit records.',
    ),
    DistillationConversationTurn(
      role: 'assistant',
      text: 'Open: remaining engine and mid-task switch nodes.',
    ),
  ];

  DistillationRequest request({bool Function(String agentId)? isReady}) {
    return DistillationRequest(
      sourceSessionId: 'session-src-1',
      sourceAgentId: 'claude-code',
      targetAgentId: 'codex',
      turns: turns,
      isDistillerReady: isReady ?? (_) => true,
      now: () => DateTime.utc(2026, 7, 11, 4),
    );
  }

  String goodPackageJson() {
    return jsonEncode({
      'objective': 'Ship the routing module with hot reload.',
      'currentState': 'Policy schema landed; broker in progress.',
      'decisions': [
        'Use declarative policy files as the sole metadata authority.',
      ],
      'constraints': ['Must not store raw conversation text in audit records.'],
      'openItems': ['Remaining engine and mid-task switch nodes.'],
    });
  }

  RoutingPolicyDocument directivePolicy({int maxLength = 512}) {
    return RoutingPolicyDocument(
      schemaVersion: 2,
      id: 'agent-directive',
      agents: [
        RoutingPolicyAgent(
          id: 'claude-code',
          distillation: RoutingAgentDistillation(
            distiller: 'directive-distiller',
            maxLength: maxLength,
            preserveFields: const ['openItems'],
          ),
        ),
      ],
      distillation: const RoutingPolicyDistillation(
        defaultDistiller: 'global-distiller',
        alternateDistiller: 'alternate-distiller',
        fidelityContract: RoutingFidelityContract(
          requiredSections: ['objective'],
          maxPackageLength: 8192,
          retryOnFailure: false,
        ),
      ),
    );
  }
}
