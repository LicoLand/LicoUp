import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/misc.dart' show ProviderListenable;
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/composition/features/mobile_relay/mobile_relay_feature_composition.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_inputs.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_providers.dart';

void main() {
  test('the feature composition supplies every mobile relay region', () async {
    final controller = ClientController();
    final feature = MobileRelayFeatureComposition(
      relay: controller.mobileRelayController,
      secureMesh: controller.secureMeshController,
      homeLayout: controller.mobileHomeLayoutController,
      readMobileRuntime: () => controller.mobileClientRuntimePlatform,
    );
    final container = ProviderContainer(overrides: feature.providerOverrides);
    final listeners = <ProviderSubscription<Object?>>[
      container.listen(mobileRelayPairingInputsProvider, (_, _) {}),
      container.listen(mobileRelayTrustInputsProvider, (_, _) {}),
      container.listen(mobileRelayApprovalsInputsProvider, (_, _) {}),
      container.listen(mobileRelayTransfersInputsProvider, (_, _) {}),
      container.listen(mobileRelayCapabilitiesInputsProvider, (_, _) {}),
      container.listen(mobileRelayHomeInputsProvider, (_, _) {}),
    ];
    addTearDown(() async {
      for (final listener in listeners) {
        listener.close();
      }
      container.dispose();
      await feature.dispose();
      controller.dispose();
    });

    expect(
      await _resolve(container, mobileRelayPairingInputsProvider),
      isA<MobileRelayPairingInputs>(),
    );
    expect(
      await _resolve(container, mobileRelayTrustInputsProvider),
      isA<MobileRelayTrustInputs>(),
    );
    expect(
      await _resolve(container, mobileRelayApprovalsInputsProvider),
      isA<MobileRelayApprovalsInputs>(),
    );
    expect(
      await _resolve(container, mobileRelayTransfersInputsProvider),
      isA<MobileRelayTransfersInputs>(),
    );
    expect(
      await _resolve(container, mobileRelayCapabilitiesInputsProvider),
      isA<MobileRelayCapabilitiesInputs>(),
    );
    expect(
      await _resolve(container, mobileRelayHomeInputsProvider),
      isA<MobileRelayHomeInputs>(),
    );
  });
}

Future<T> _resolve<T>(
  ProviderContainer container,
  ProviderListenable<AsyncValue<T>> provider,
) async {
  for (var attempt = 0; attempt < 50; attempt += 1) {
    final value = container.read(provider);
    if (value.hasValue) return value.requireValue;
    await Future<void>.delayed(Duration.zero);
  }
  fail('mobile relay region never resolved: ${container.read(provider)}');
}
