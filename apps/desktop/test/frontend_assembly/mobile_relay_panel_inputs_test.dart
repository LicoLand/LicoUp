// V7-FI: the relay station input follows real admitted values.
//
// The panel no longer reads the raw relay projection owner. Its station input
// is driven by the admitted pairing region through the composition runtime, so
// a same-input repaint keeps the local draft, a real admitted change replaces
// it, and a revoked region makes the withdrawn value invisible instead of
// falling back to the owner.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/composition/client_app_composition.dart';
import 'package:licoup/src/contracts/mobile_relay/mobile_relay_config.dart';
import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/mobile_relay_panel/composition.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_providers.dart';

import '../layout/fixtures/production_client_shell_fixture.dart';

const _stationFieldKey = Key('mobile-relay-station-base-url-field');

MobileRelayConfig _stationConfig(String stationBaseUrl) => MobileRelayConfig(
  schemaVersion: MobileRelayConfig.currentSchemaVersion,
  stationBaseUrl: stationBaseUrl,
  pcClientId: '',
  pcClientName: 'Fixture Desktop',
  pairingId: '',
  pcToken: '',
  mobileToken: '',
  lastPairingCode: '',
  lastPairingExpiresAt: '',
  paired: false,
  relayEnabled: false,
  pollIntervalSeconds: 5,
  pcTokenPresent: false,
  mobileTokenPresent: false,
);

Widget _panelApp(ClientAppComposition composition) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: buildLicoTheme(
    presetId: 'default-system',
    platformBrightness: Brightness.dark,
  ).copyWith(platform: TargetPlatform.macOS),
  home: ProviderScope(
    overrides: composition.presentationOverrides,
    child: Scaffold(body: MobileRelayPanel(binding: composition.mobileRelay)),
  ),
);

Finder _stationField() => find.descendant(
  of: find.byKey(_stationFieldKey),
  matching: find.byType(TextField),
);

String? _stationFieldText(WidgetTester tester) {
  final finder = _stationField();
  if (finder.evaluate().isEmpty) return null;
  return tester.widget<TextField>(finder).controller?.text;
}

void main() {
  testWidgets(
    'station input follows admitted values, keeps drafts, hides revocations',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1180, 760));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final fixture = await ProductionClientShellFixture.create(
        profileId: LayoutProfileId.parse('dashboard'),
        surface: LayoutRuntimeSurface.desktop,
        destination: ClientSection.mobileRelay,
        size: const Size(1180, 760),
        brightness: Brightness.dark,
      );
      addTearDown(fixture.dispose);
      fixture.controller.mobileRelayConfig = _stationConfig(
        'https://station.alpha.test',
      );
      final composition = ClientAppComposition(controller: fixture.controller);
      addTearDown(composition.dispose);
      final runtime = composition.presentationRuntime;
      try {
        await tester.pumpWidget(_panelApp(composition));
        await tester.pump();
        await tester.pump();
        expect(
          _stationFieldText(tester),
          'https://station.alpha.test',
          reason: 'the station input never followed the admitted value',
        );

        // A local draft survives a same-input repaint: the guard keys on the
        // admitted value, not on the controller text.
        await tester.enterText(_stationField(), 'https://draft.local');
        await tester.pump();
        await tester.pumpWidget(_panelApp(composition));
        await tester.pump();
        await tester.pump();
        expect(_stationFieldText(tester), 'https://draft.local');

        // A real admitted change replaces the input.
        fixture.controller.mobileRelayConfig = _stationConfig(
          'https://station.beta.test',
        );
        await tester.pump();
        await tester.pump();
        expect(_stationFieldText(tester), 'https://station.beta.test');

        // Revocation makes the withdrawn admitted value invisible while the
        // relay owner still holds it.
        final container = ProviderScope.containerOf(
          tester.element(find.byType(MobileRelayPanel)),
        );
        final source = container.read(mobileRelayPairingSourceProvider);
        expect(
          fixture.controller.mobileRelayConfig.stationBaseUrl,
          'https://station.beta.test',
        );
        runtime.revoke(source.fieldGroup.resource);
        await tester.pump();
        expect(find.byKey(_stationFieldKey), findsNothing);

        final lease = runtime.own(source);
        addTearDown(lease.release);
        await lease.reconnect();
        await tester.pump();
        await tester.pump();
        expect(_stationFieldText(tester), 'https://station.beta.test');
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(composition.dispose);
      }
    },
  );
}
