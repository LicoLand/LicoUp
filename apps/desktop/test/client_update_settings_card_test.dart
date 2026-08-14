import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/contracts/client_process_lifecycle.dart';
import 'package:licoup/src/contracts/client_update_models.dart';
import 'package:licoup/src/frontend/features/settings/ui/client_update_settings_card.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

import 'layout/fixtures/layout_destination_presentation_fixture.dart';

void main() {
  testWidgets('card shows three actions, running version, and source address', (
    tester,
  ) async {
    final controller = _UpdateController(
      status: const ClientUpdateStatus(
        phase: ClientUpdatePhase.idle,
        currentVersion: '0.1.0',
        channel: 'stable',
      ),
    );
    addTearDown(controller.dispose);

    await _pumpCard(tester, controller, locale: const Locale('zh'));

    expect(find.text('检查更新'), findsOneWidget);
    expect(find.text('下载到本地'), findsOneWidget);
    expect(find.text('更新并重启'), findsOneWidget);
    expect(find.text('0.1.0'), findsOneWidget);
    expect(find.text('未选择'), findsNothing);
    expect(find.text('源地址'), findsOneWidget);
    expect(find.text(kClientUpdateGithubReleasesUrl), findsOneWidget);
    expect(find.text('状态'), findsNothing);
    expect(find.text('失败'), findsNothing);
    expect(find.text('生产就绪'), findsNothing);
    expect(find.text('是'), findsNothing);
    expect(find.text('否'), findsNothing);
    expect(find.byKey(const Key('client-update-refresh-status')), findsNothing);
    expect(find.byKey(const Key('client-update-verify')), findsNothing);
    expect(find.byKey(const Key('client-update-apply-plan')), findsNothing);
    expect(find.byKey(const Key('client-update-rollback')), findsNothing);
    expect(find.byKey(const Key('client-update-check-github')), findsOneWidget);
    expect(
      find.byKey(const Key('client-update-download-local')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('client-update-apply-restart')),
      findsOneWidget,
    );

    expect(_onPressed(tester, 'client-update-check-github'), isNotNull);
    expect(_onPressed(tester, 'client-update-download-local'), isNull);
    expect(_onPressed(tester, 'client-update-apply-restart'), isNull);
  });

  testWidgets('download stays disabled without a newer signed release', (
    tester,
  ) async {
    final controller = _UpdateController(
      status: const ClientUpdateStatus(
        phase: ClientUpdatePhase.upToDate,
        currentVersion: '1.0.0',
        channel: 'stable',
      ),
    );
    addTearDown(controller.dispose);

    await _pumpCard(tester, controller);

    expect(_onPressed(tester, 'client-update-check-github'), isNotNull);
    expect(_onPressed(tester, 'client-update-download-local'), isNull);
    expect(_onPressed(tester, 'client-update-apply-restart'), isNull);
  });

  testWidgets('apply stays disabled without a verified local artifact', (
    tester,
  ) async {
    final controller = _UpdateController(
      status: const ClientUpdateStatus(
        phase: ClientUpdatePhase.updateAvailable,
        currentVersion: '1.0.0',
        channel: 'stable',
        availableVersion: '1.1.0',
        updateAvailable: true,
        githubReleaseUrl:
            'https://github.com/LicoLand/LicoUp/releases/tag/v1.1.0',
      ),
    );
    addTearDown(controller.dispose);

    await _pumpCard(tester, controller);

    expect(
      find.text('https://github.com/LicoLand/LicoUp/releases/tag/v1.1.0'),
      findsOneWidget,
    );
    expect(_onPressed(tester, 'client-update-check-github'), isNotNull);
    expect(_onPressed(tester, 'client-update-download-local'), isNotNull);
    expect(_onPressed(tester, 'client-update-apply-restart'), isNull);
  });

  testWidgets('check failure does not enable download or apply', (
    tester,
  ) async {
    final controller = _UpdateController(
      status: const ClientUpdateStatus(
        phase: ClientUpdatePhase.failed,
        currentVersion: '0.1.0',
        channel: 'stable',
        errorCode: 'client_update_check_failed',
      ),
    );
    addTearDown(controller.dispose);

    await _pumpCard(tester, controller, locale: const Locale('zh'));

    expect(find.text('0.1.0'), findsOneWidget);
    expect(find.text('失败'), findsNothing);
    expect(find.text('状态'), findsNothing);
    expect(_onPressed(tester, 'client-update-check-github'), isNotNull);
    expect(_onPressed(tester, 'client-update-download-local'), isNull);
    expect(_onPressed(tester, 'client-update-apply-restart'), isNull);
  });

  testWidgets('apply and restart delegates process exit to the platform port', (
    tester,
  ) async {
    final lifecycle = _RecordingProcessLifecycle();
    final controller = _UpdateController(
      processLifecycle: lifecycle,
      status: const ClientUpdateStatus(
        phase: ClientUpdatePhase.verified,
        currentVersion: '1.0.0',
        channel: 'stable',
        availableVersion: '1.1.0',
        updateAvailable: true,
      ),
    );
    addTearDown(controller.dispose);

    await _pumpCard(tester, controller);

    expect(_onPressed(tester, 'client-update-download-local'), isNull);
    expect(_onPressed(tester, 'client-update-apply-restart'), isNotNull);

    await tester.tap(find.byKey(const Key('client-update-apply-restart')));
    await tester.pump();

    expect(controller.applyCalls, 1);
    expect(lifecycle.exitCalls, 1);
  });
}

Future<void> _pumpCard(
  WidgetTester tester,
  ClientController controller, {
  Locale locale = const Locale('en'),
}) async {
  await tester.pumpWidget(
    MaterialApp(
      locale: locale,
      builder: (context, child) =>
          FixtureLayoutPresentationScope(child: child!),
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
}

VoidCallback? _onPressed(WidgetTester tester, String key) {
  final widget = tester.widget<ButtonStyleButton>(find.byKey(Key(key)));
  return widget.onPressed;
}

final class _UpdateController extends ClientController {
  _UpdateController({
    required this.status,
    ClientProcessLifecycle? processLifecycle,
  }) : super(clientProcessLifecycle: processLifecycle);

  final ClientUpdateStatus status;
  int applyCalls = 0;

  @override
  ClientUpdateStatus get clientUpdateStatus => status;

  @override
  bool get isClientUpdateBusy => false;

  @override
  String get clientUpdateSource => 'github';

  @override
  String get clientUpdateRepo => kClientUpdateGithubRepo;

  @override
  Future<void> hydrateClientUpdateIdentity({String channel = 'stable'}) async {}

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
