import 'dart:convert';

import 'package:flutter_client/src/application/features/routing/broker/distillation_broker.dart';
import 'package:flutter_client/src/contracts/routing/distillation_package.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/distillation_broker_harness.dart';

void main() {
  late DistillationBrokerHarness harness;
  setUpAll(() => harness = DistillationBrokerHarness.load());

  test(
    'audit sink stores package and source references but no source turns',
    () async {
      final sink = <DistillationAuditRecord>[];
      final result = await DefaultDistillationBroker(auditSink: sink).distill(
        request: harness.request(),
        policy: harness.policy,
        send: (_) async => DistillationLaneResponse(
          ok: true,
          text: harness.goodPackageJson(),
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
      expect(encoded, isNot(contains('Goal: ship the routing module')));
      expect(encoded, isNot(contains('role')));
      expect(encoded, isNot(contains('turns')));
    },
  );
}
