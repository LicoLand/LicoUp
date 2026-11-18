import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/application/features/devices/devices_controller.dart';
import 'package:licoup/src/backend/features/devices/devices_service.dart';
import 'package:licoup/src/composition/features/devices/devices_feature_composition.dart';
import 'package:licoup/src/frontend/features/devices/ui/devices_panel.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

import 'support/fake_devices_cli.dart';

void main() {
  late FakeDevicesCli cli;
  late FakeDevicesNoticeRepository notice;
  late List<String> clipboard;

  Future<DevicesController> pumpPanel(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1100, 1600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final controller = DevicesController(
      service: DevicesService(runner: cli),
      noticeRepository: notice,
      writeClipboard: (text) async {
        clipboard.add(text);
        return true;
      },
      // Progress re-reads are covered by the controller test.
      createTimer: (_, _) => _InertTimer(),
      newIntentId: () => 'intent-1',
    );
    final feature = DevicesFeatureComposition(controller);
    addTearDown(() async {
      await feature.dispose();
      controller.dispose();
    });
    await controller.loadNoticeAcknowledgement();
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: LicoStrings.supportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        theme: buildLicoTheme(platformBrightness: Brightness.light),
        home: Scaffold(body: DevicesPanel(binding: feature.binding)),
      ),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  setUp(() {
    cli = FakeDevicesCli();
    notice = FakeDevicesNoticeRepository();
    clipboard = [];
  });

  testWidgets('an unenrolled device shows the enrollment card and joins', (
    tester,
  ) async {
    await pumpPanel(tester);
    expect(cli.callsOf('status'), 1);
    expect(find.byKey(const Key('devices-enroll-card')), findsOneWidget);
    expect(find.byKey(const Key('devices-pairing-card')), findsNothing);

    await tester.enterText(
      find.byKey(const Key('devices-enroll-station')),
      'https://station.example.test',
    );
    await tester.enterText(
      find.byKey(const Key('devices-enroll-invitation')),
      'btm1.synthetic',
    );
    await tester.tap(find.byKey(const Key('devices-enroll-submit')));
    await tester.pumpAndSettle();

    expect(cli.stdinPayloads.single['station'], 'https://station.example.test');
    expect(find.byKey(const Key('devices-enroll-card')), findsNothing);
    expect(find.byKey(const Key('devices-station-card')), findsOneWidget);
    expect(find.byKey(const Key('devices-pairing-card')), findsOneWidget);
    expect(find.text('Joined the station'), findsOneWidget);
  });

  testWidgets('an invalid station shows the failure inline', (tester) async {
    await pumpPanel(tester);
    await tester.enterText(
      find.byKey(const Key('devices-enroll-station')),
      'http://plain.example',
    );
    await tester.tap(find.byKey(const Key('devices-enroll-submit')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('devices-failure')), findsOneWidget);
    expect(cli.callsOf('enroll'), 0);
  });

  testWidgets('the legacy pairing notice shows once and can be dismissed', (
    tester,
  ) async {
    cli.legacyPairingsDetected = true;
    await pumpPanel(tester);
    expect(find.byKey(const Key('devices-legacy-notice')), findsOneWidget);
    await tester.tap(find.byKey(const Key('devices-legacy-notice-dismiss')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('devices-legacy-notice')), findsNothing);
    expect(notice.acknowledged, isTrue);
  });

  testWidgets('an acknowledged legacy notice stays hidden', (tester) async {
    cli.legacyPairingsDetected = true;
    notice.acknowledged = true;
    await pumpPanel(tester);
    expect(find.byKey(const Key('devices-legacy-notice')), findsNothing);
  });

  testWidgets('offering shows a copyable code and the pending pairing', (
    tester,
  ) async {
    cli.enrolled = true;
    await pumpPanel(tester);
    await tester.enterText(find.byKey(const Key('devices-pair-label')), 'Air');
    await tester.tap(find.byKey(const Key('devices-pair-offer')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('devices-pair-offered-code')), findsOneWidget);
    expect(find.text('code-pair-offer-1'), findsOneWidget);
    expect(find.text('Waiting for the other device'), findsOneWidget);

    await tester.tap(find.byKey(const Key('devices-pair-copy-code')));
    await tester.pumpAndSettle();
    expect(clipboard, ['code-pair-offer-1']);
    expect(find.text('Pairing code copied'), findsOneWidget);

    await tester.tap(
      find.byKey(const Key('devices-pairing-cancel-pair-offer-1')),
    );
    await tester.pumpAndSettle();
    expect(cli.callsOf('pair cancel'), 1);
    expect(find.byKey(const Key('devices-pair-offered-code')), findsNothing);
  });

  testWidgets('claiming a code shows the pairing waiting for confirmation', (
    tester,
  ) async {
    cli.enrolled = true;
    await pumpPanel(tester);
    await tester.enterText(
      find.byKey(const Key('devices-pair-claim-code')),
      'lap1.code',
    );
    await tester.tap(find.byKey(const Key('devices-pair-claim')));
    await tester.pumpAndSettle();
    expect(cli.stdinPayloads.single['code'], 'lap1.code');
    expect(find.text('Waiting for confirmation'), findsOneWidget);
  });

  testWidgets('a failed claim surfaces its code', (tester) async {
    cli
      ..enrolled = true
      ..failures['pair claim'] = 'devices_pairing_code_invalid';
    await pumpPanel(tester);
    await tester.enterText(
      find.byKey(const Key('devices-pair-claim-code')),
      'bad',
    );
    await tester.tap(find.byKey(const Key('devices-pair-claim')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('devices-failure')), findsOneWidget);
    expect(find.text('devices_pairing_code_invalid'), findsWidgets);
  });

  testWidgets('enrolled without peers shows the empty peers state', (
    tester,
  ) async {
    cli.enrolled = true;
    await pumpPanel(tester);
    expect(find.byKey(const Key('devices-peers-empty')), findsOneWidget);
    expect(find.byKey(const Key('devices-message-card')), findsNothing);
  });

  testWidgets('a paired device receives a message and shows its results', (
    tester,
  ) async {
    cli
      ..enrolled = true
      ..answerMessagesImmediately = true
      ..peers.addAll([
        FakeDevicesCli.peer('peer-1', 'Studio'),
        FakeDevicesCli.peer('peer-2', 'Air'),
      ]);
    await pumpPanel(tester);
    expect(find.byKey(const Key('devices-message-card')), findsOneWidget);
    expect(find.byKey(const Key('devices-results-empty')), findsOneWidget);

    await tester.tap(find.byKey(const Key('devices-peer-peer-2')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('devices-message-agent')),
      'codex',
    );
    await tester.enterText(
      find.byKey(const Key('devices-message-body')),
      'run the tests',
    );
    await tester.tap(find.byKey(const Key('devices-message-send')));
    await tester.pumpAndSettle();

    expect(
      cli.calls.firstWhere((call) => call.contains('send')),
      contains('peer-2'),
    );
    expect(cli.stdinPayloads.single['body'], 'run the tests');
    expect(find.byKey(const Key('devices-result-cmd-1')), findsOneWidget);
    expect(find.text('synthetic reply'), findsOneWidget);
  });

  testWidgets('outstanding messages are counted until their result arrives', (
    tester,
  ) async {
    cli
      ..enrolled = true
      ..peers.add(FakeDevicesCli.peer('peer-1', 'Studio'));
    await pumpPanel(tester);
    await tester.enterText(
      find.byKey(const Key('devices-message-agent')),
      'codex',
    );
    await tester.enterText(find.byKey(const Key('devices-message-body')), 'hi');
    await tester.tap(find.byKey(const Key('devices-message-send')));
    await tester.pumpAndSettle();
    expect(find.text('Waiting for 1 result'), findsOneWidget);
  });

  testWidgets('unpairing asks for confirmation', (tester) async {
    cli
      ..enrolled = true
      ..peers.add(FakeDevicesCli.peer('peer-1', 'Studio'));
    await pumpPanel(tester);
    await tester.tap(find.byKey(const Key('devices-peer-unpair-peer-1')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('devices-unpair-confirm')), findsOneWidget);
    await tester.tap(find.byKey(const Key('devices-unpair-confirm-submit')));
    await tester.pumpAndSettle();
    expect(cli.callsOf('unpair'), 1);
    expect(find.byKey(const Key('devices-peers-empty')), findsOneWidget);
  });
}

final class _InertTimer implements Timer {
  @override
  bool get isActive => false;

  @override
  int get tick => 0;

  @override
  void cancel() {}
}
