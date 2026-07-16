import 'package:flutter_client/src/application/features/routing/broker/distillation_broker.dart';
import 'package:flutter_client/src/contracts/routing/distillation_package.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/distillation_broker_harness.dart';

void main() {
  late DistillationBrokerHarness harness;
  setUpAll(() => harness = DistillationBrokerHarness.load());

  test('broker assembles a full source-referenced handoff package', () async {
    final result = await DefaultDistillationBroker().distill(
      request: harness.request(),
      policy: harness.policy,
      send: (laneRequest) async {
        expect(laneRequest.agentId, 'fake-distiller');
        expect(laneRequest.text, contains('Goal: ship the routing module'));
        return DistillationLaneResponse(
          ok: true,
          text: harness.goodPackageJson(),
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
  });

  test(
    'per-agent directive controls distiller, fields, and max length',
    () async {
      DistillationLaneRequest? dispatched;
      final success = await DefaultDistillationBroker().distill(
        request: harness.request(),
        policy: harness.directivePolicy(),
        send: (laneRequest) async {
          dispatched = laneRequest;
          return DistillationLaneResponse(
            ok: true,
            text: harness.goodPackageJson(),
          );
        },
      );
      expect(success, isA<DistillationSuccess>());
      expect(dispatched?.agentId, 'directive-distiller');
      expect(dispatched?.text, contains('openItems'));
      expect(
        (success as DistillationSuccess).fidelity.checkedSections,
        contains('openItems'),
      );

      final failure = await DefaultDistillationBroker().distill(
        request: harness.request(),
        policy: harness.directivePolicy(maxLength: 32),
        send: (_) async =>
            DistillationLaneResponse(ok: true, text: harness.goodPackageJson()),
      );
      expect(failure, isA<DistillationFailure>());
      expect(
        (failure as DistillationFailure).reason,
        contains('maxPackageLength 32'),
      );
    },
  );
}
