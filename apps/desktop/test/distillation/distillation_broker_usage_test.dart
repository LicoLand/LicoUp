import 'package:flutter_client/src/application/features/routing/broker/distillation_broker.dart';
import 'package:flutter_client/src/contracts/routing/distillation_package.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/distillation_broker_harness.dart';

void main() {
  late DistillationBrokerHarness harness;
  setUpAll(() => harness = DistillationBrokerHarness.load());

  test(
    'failed retries and success both project exact dispatch usage',
    () async {
      var calls = 0;
      final failure = await DefaultDistillationBroker().distill(
        request: harness.request(),
        policy: harness.policy,
        send: (_) async {
          calls += 1;
          return const DistillationLaneResponse(
            ok: true,
            promptTokens: 40,
            completionTokens: 10,
          );
        },
      );

      expect(failure, isA<DistillationFailure>());
      expect(calls, 2);
      final failedUsage = (failure as DistillationFailure).usage;
      expect(failedUsage.dispatchCallCount, 2);
      expect(failedUsage.promptTokens, 80);
      expect(failedUsage.completionTokens, 20);
      expect(failedUsage.totalTokens, 100);

      final success =
          await DefaultDistillationBroker().distill(
                request: harness.request(),
                policy: harness.policy,
                send: (_) async => DistillationLaneResponse(
                  ok: true,
                  text: harness.goodPackageJson(),
                  promptTokens: 100,
                  completionTokens: 50,
                ),
              )
              as DistillationSuccess;
      expect(success.usage.dispatchCallCount, 1);
      expect(success.usage.totalTokens, 150);
      expect(success.audit.usage.totalTokens, 150);
    },
  );
}
