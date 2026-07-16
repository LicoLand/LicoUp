import 'dart:convert';

import 'package:flutter_client/src/application/features/routing/broker/distillation_broker.dart';
import 'package:flutter_client/src/contracts/routing/distillation_package.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/distillation_broker_harness.dart';

void main() {
  late DistillationBrokerHarness harness;
  setUpAll(() => harness = DistillationBrokerHarness.load());

  test('first fidelity failure triggers one corrective prompt', () async {
    final prompts = <DistillationLaneRequest>[];
    var attempt = 0;
    final result = await DefaultDistillationBroker().distill(
      request: harness.request(),
      policy: harness.policy,
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
              'openItems': ['Engine.'],
            }),
          );
        }
        return DistillationLaneResponse(
          ok: true,
          text: harness.goodPackageJson(),
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

  test(
    'repeated missing section projects exhausted failure without raw turns',
    () async {
      var calls = 0;
      final result = await DefaultDistillationBroker().distill(
        request: harness.request(),
        policy: harness.policy,
        send: (_) async {
          calls += 1;
          return DistillationLaneResponse(
            ok: true,
            text: jsonEncode({
              'objective': 'Ship routing.',
              'currentState': 'In progress.',
              'decisions': ['Use policy files.'],
              'constraints': <String>[],
              'openItems': ['Engine.'],
            }),
          );
        },
      );

      expect(result, isA<DistillationFailure>());
      final failure = result as DistillationFailure;
      expect(failure.retriesExhausted, isTrue);
      expect(failure.reason, contains('constraints'));
      expect(calls, 2);
      final audit = jsonEncode(failure.audit.toJson());
      expect(audit, isNot(contains('Goal: ship the routing module')));
      expect(audit, isNot(contains('role')));
    },
  );
}
