import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/contracts/client_process_lifecycle.dart';
import 'package:licoup/src/contracts/client_update_models.dart';
import 'package:licoup/src/frontend/features/settings/ui/client_update_settings_card.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

void main() {
  testWidgets('apply and restart delegates process exit to the platform port', (
    tester,
  ) async {
    final lifecycle = _RecordingProcessLifecycle();
    final controller = _UpdateController(processLifecycle: lifecycle);
    addTearDown(controller.dispose);

    await tester.pumpWidget(
      MaterialApp(
        supportedLocales: LicoStrings.supportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        theme: buildLicoTheme(platformBrightness: Brightness.dark),
        home: Scaffold(body: ClientUpdateSettingsCard(controller: controller)),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('client-update-apply-restart')));
    await tester.pump();

    expect(controller.applyCalls, 1);
    expect(lifecycle.exitCalls, 1);
  });
}

final class _UpdateController extends ClientController {
  _UpdateController({required ClientProcessLifecycle processLifecycle})
    : super(clientProcessLifecycle: processLifecycle);

  int applyCalls = 0;

  @override
  ClientUpdateStatus get clientUpdateStatus => const ClientUpdateStatus(
    phase: ClientUpdatePhase.verified,
    currentVersion: '1.0.0',
    channel: 'stable',
    availableVersion: '1.1.0',
    updateAvailable: true,
    productionReady: true,
  );

  @override
  bool get isClientUpdateBusy => false;

  @override
  String get clientUpdateSource => 'github';

  @override
  Future<void> applyClientUpdateThenExit(void Function() exitClient) async {
    applyCalls += 1;
    exitClient();
  }
}

final class _RecordingProcessLifecycle implements ClientProcessLifecycle {
  int exitCalls = 0;

  @override
  void exitSuccess() => exitCalls += 1;
}
