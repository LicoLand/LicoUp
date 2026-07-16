import 'package:flutter_client/src/application/features/routing/broker/distillation_broker.dart';
import 'package:flutter_client/src/contracts/routing/distillation_package.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/distillation_broker_harness.dart';

void main() {
  late DistillationBrokerHarness harness;
  setUpAll(() => harness = DistillationBrokerHarness.load());

  test(
    'alternate distiller is selected when the primary is not ready',
    () async {
      String? used;
      final result = await DefaultDistillationBroker().distill(
        request: harness.request(isReady: (id) => id != 'fake-distiller'),
        policy: harness.policy,
        send: (laneRequest) async {
          used = laneRequest.agentId;
          return DistillationLaneResponse(
            ok: true,
            text: harness.goodPackageJson(),
          );
        },
      );

      expect(result, isA<DistillationSuccess>());
      expect(used, 'claude-code');
    },
  );

  test('unavailable distillers fail before dispatch', () async {
    var calls = 0;
    final result = await DefaultDistillationBroker().distill(
      request: harness.request(isReady: (_) => false),
      policy: harness.policy,
      send: (_) async {
        calls += 1;
        return const DistillationLaneResponse(ok: true);
      },
    );

    expect(result, isA<DistillationFailure>());
    expect((result as DistillationFailure).distillerUnavailable, isTrue);
    expect(calls, 0);
  });

  test('lane errors remain fail-closed without undistilled handoff', () async {
    final result = await DefaultDistillationBroker().distill(
      request: harness.request(),
      policy: harness.policy,
      send: (_) async => const DistillationLaneResponse(
        ok: false,
        errorMessage: 'lane not ready',
      ),
    );

    expect(result, isA<DistillationFailure>());
    final failure = result as DistillationFailure;
    expect(failure.reason, contains('lane not ready'));
    expect(failure.audit.package, isNull);
  });
}
