import 'dart:convert';
import 'dart:io';

import 'package:flutter_client/src/application/features/routing/broker/distillation_broker.dart';
import 'package:flutter_client/src/contracts/routing/distillation_package.dart';
import 'package:flutter_client/src/contracts/routing/routing_policy_schema.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late RoutingPolicyDocument policy;
  late List<DistillationConversationTurn> fixtureTurns;

  setUpAll(() {
    final source = File(
      'test/fixtures/routing/distill-policy.json',
    ).readAsStringSync();
    final parsed = parseRoutingPolicyDocument(source);
    expect(parsed, isA<RoutingPolicyParseSuccess>());
    policy = (parsed as RoutingPolicyParseSuccess).document;
  });

  setUp(() {
    fixtureTurns = const [
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
        text: 'Decision: use declarative policy files as the sole metadata authority.',
      ),
      DistillationConversationTurn(
        role: 'user',
        text: 'Constraint: must not store raw conversation text in audit records.',
      ),
      DistillationConversationTurn(
        role: 'assistant',
        text: 'Open: remaining engine and mid-task switch nodes.',
      ),
    ];
  });

  DistillationRequest request({
    bool Function(String agentId)? isReady,
  }) {
    return DistillationRequest(
      sourceSessionId: 'session-src-1',
      sourceAgentId: 'claude-code',
      targetAgentId: 'codex',
      turns: fixtureTurns,
      isDistillerReady: isReady ?? (_) => true,
      now: () => DateTime.utc(2026, 7, 11, 4, 0, 0),
    );
  }

  String goodPackageJson() {
    return jsonEncode({
      'objective': 'Ship the routing module with hot reload.',
      'currentState': 'Policy schema landed; broker in progress.',
      'decisions': [
        'Use declarative policy files as the sole metadata authority.',
      ],
      'constraints': [
        'Must not store raw conversation text in audit records.',
      ],
      'openItems': ['Remaining engine and mid-task switch nodes.'],
    });
  }

  group('V-003-A handoff package assembly', () {
    test('broker produces a full package from a fixture conversation', () async {
      final broker = DefaultDistillationBroker();
      final result = await broker.distill(
        request: request(),
        policy: policy,
        send: (laneRequest) async {
          expect(laneRequest.agentId, 'fake-distiller');
          expect(laneRequest.text, contains('Goal: ship the routing module'));
          return DistillationLaneResponse(
            ok: true,
            text: goodPackageJson(),
            promptTokens: 120,
            completionTokens: 80,
          );
        },
      );

      expect(result, isA<DistillationSuccess>());
      final success = result as DistillationSuccess;
      expect(success.package.hasObjective, isTrue);
      expect(success.package.hasCurrentState, isTrue);
      expect(success.package.hasDecisions, isTrue);
      expect(success.package.hasConstraints, isTrue);
      expect(success.package.hasOpenItems, isTrue);
      expect(success.package.sourceSessionId, 'session-src-1');
      expect(success.package.sourceAgentId, 'claude-code');
    });
  });

  group('V-003-B / V-003-C fidelity validation', () {
    test('package with all required sections passes', () {
      final package = DistillationPackage.fromJson(
        jsonDecode(goodPackageJson()) as Map<String, dynamic>,
      );
      final fidelity = checkDistillationFidelity(
        package: package,
        contract: policy.distillation.fidelityContract,
        sourceClasses: DistillationSourceContentClasses.detect(fixtureTurns),
      );
      expect(fidelity.passed, isTrue);
      expect(fidelity.missingSections, isEmpty);
    });

    test('missing required section fails closed with no raw handoff', () async {
      final broker = DefaultDistillationBroker();
      var calls = 0;
      final result = await broker.distill(
        request: request(),
        policy: policy,
        send: (laneRequest) async {
          calls += 1;
          // Always return package missing constraints.
          return DistillationLaneResponse(
            ok: true,
            text: jsonEncode({
              'objective': 'Ship routing.',
              'currentState': 'In progress.',
              'decisions': ['Use policy files.'],
              'constraints': <String>[],
              'openItems': ['Engine.'],
            }),
            promptTokens: 10,
            completionTokens: 10,
          );
        },
      );

      expect(result, isA<DistillationFailure>());
      final failure = result as DistillationFailure;
      expect(failure.retriesExhausted, isTrue);
      expect(failure.reason, contains('constraints'));
      expect(calls, 2); // initial + one corrective retry
      // Fail-closed: no success path, no raw transcript in audit.
      final auditJson = jsonEncode(failure.audit.toJson());
      expect(auditJson.contains('must not store raw'), isFalse);
      expect(auditJson.contains('Goal: ship the routing module'), isFalse);
    });
  });

  group('V-003-D corrective retry', () {
    test('first fidelity failure triggers exactly one corrective re-prompt', () async {
      final broker = DefaultDistillationBroker();
      final prompts = <DistillationLaneRequest>[];
      var attempt = 0;
      final result = await broker.distill(
        request: request(),
        policy: policy,
        send: (laneRequest) async {
          prompts.add(laneRequest);
          attempt += 1;
          if (attempt == 1) {
            return DistillationLaneResponse(
              ok: true,
              text: jsonEncode({
                'objective': 'Ship routing.',
                'currentState': 'In progress.',
                'decisions': ['Use policy files.'],
                // missing constraints
                'openItems': ['Engine.'],
              }),
              promptTokens: 11,
              completionTokens: 9,
            );
          }
          return DistillationLaneResponse(
            ok: true,
            text: goodPackageJson(),
            promptTokens: 12,
            completionTokens: 20,
          );
        },
      );

      expect(result, isA<DistillationSuccess>());
      expect(prompts, hasLength(2));
      expect(prompts.first.corrective, isFalse);
      expect(prompts.last.corrective, isTrue);
      expect(prompts.last.text, contains('CORRECTIVE'));
      expect(prompts.last.text, contains('constraints'));
    });

    test('second failure surfaces error to caller', () async {
      final broker = DefaultDistillationBroker();
      final result = await broker.distill(
        request: request(),
        policy: policy,
        send: (_) async => const DistillationLaneResponse(
          ok: true,
          text: '{"objective":"x"}',
          promptTokens: 1,
          completionTokens: 1,
        ),
      );
      expect(result, isA<DistillationFailure>());
      expect((result as DistillationFailure).retriesExhausted, isTrue);
    });
  });

  group('V-003-E alternate-distiller fallback', () {
    test('falls back to alternate when primary is non-ready', () async {
      final broker = DefaultDistillationBroker();
      String? used;
      final result = await broker.distill(
        request: request(
          isReady: (id) => id != 'fake-distiller',
        ),
        policy: policy,
        send: (laneRequest) async {
          used = laneRequest.agentId;
          return DistillationLaneResponse(
            ok: true,
            text: goodPackageJson(),
            promptTokens: 5,
            completionTokens: 5,
          );
        },
      );
      expect(result, isA<DistillationSuccess>());
      expect(used, 'claude-code');
    });

    test('surfaces error when both distillers are non-ready', () async {
      final broker = DefaultDistillationBroker();
      var calls = 0;
      final result = await broker.distill(
        request: request(isReady: (_) => false),
        policy: policy,
        send: (_) async {
          calls += 1;
          return const DistillationLaneResponse(ok: true, text: '{}');
        },
      );
      expect(result, isA<DistillationFailure>());
      expect((result as DistillationFailure).distillerUnavailable, isTrue);
      expect(calls, 0);
    });
  });

  group('V-003-F audit storage with source references only', () {
    test('audit contains package and fidelity but never raw source text', () async {
      final sink = <DistillationAuditRecord>[];
      final broker = DefaultDistillationBroker(auditSink: sink);
      final result = await broker.distill(
        request: request(),
        policy: policy,
        send: (_) async => DistillationLaneResponse(
          ok: true,
          text: goodPackageJson(),
          promptTokens: 3,
          completionTokens: 4,
        ),
      );
      expect(result, isA<DistillationSuccess>());
      expect(sink, hasLength(1));
      final audit = sink.single;
      expect(audit.sourceSessionId, 'session-src-1');
      expect(audit.sourceAgentId, 'claude-code');
      expect(audit.package, isNotNull);
      expect(audit.fidelity?.passed, isTrue);

      final encoded = jsonEncode(audit.toJson());
      // Source refs present.
      expect(encoded, contains('session-src-1'));
      // Raw fixture phrases must not appear beyond distilled package fields.
      expect(encoded.contains('Goal: ship the routing module with hot reload.'), isFalse);
      expect(encoded.contains('role":"user"'), isFalse);
      expect(encoded.contains('"turns"'), isFalse);
    });
  });

  group('V-003-G distillation cost metering', () {
    test('dispatch-lane calls and token cost appear in usage', () async {
      final broker = DefaultDistillationBroker();
      var calls = 0;
      final result = await broker.distill(
        request: request(),
        policy: policy,
        send: (_) async {
          calls += 1;
          return const DistillationLaneResponse(
            ok: true,
            text: '', // force retry then success path via second call
            promptTokens: 40,
            completionTokens: 10,
          );
        },
      );

      // First empty response fails parse; second also empty → failure with 2 calls.
      // Use a dedicated success path for metering clarity:
      expect(calls, 2);
      expect(result, isA<DistillationFailure>());
      final failure = result as DistillationFailure;
      expect(failure.usage.dispatchCallCount, 2);
      expect(failure.usage.promptTokens, 80);
      expect(failure.usage.completionTokens, 20);
      expect(failure.usage.totalTokens, 100);

      final successBroker = DefaultDistillationBroker();
      final success = await successBroker.distill(
        request: request(),
        policy: policy,
        send: (_) async => DistillationLaneResponse(
          ok: true,
          text: goodPackageJson(),
          promptTokens: 100,
          completionTokens: 50,
        ),
      ) as DistillationSuccess;
      expect(success.usage.dispatchCallCount, 1);
      expect(success.usage.totalTokens, 150);
      expect(success.audit.usage.totalTokens, 150);
    });
  });

  group('fail-closed raw handoff', () {
    test('no success path returns undistilled raw context', () async {
      final broker = DefaultDistillationBroker();
      final result = await broker.distill(
        request: request(),
        policy: policy,
        send: (_) async => const DistillationLaneResponse(
          ok: false,
          errorMessage: 'lane not ready',
        ),
      );
      expect(result, isA<DistillationFailure>());
      expect((result as DistillationFailure).reason, contains('lane not ready'));
    });
  });
}
