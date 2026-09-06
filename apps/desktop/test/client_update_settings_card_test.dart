import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/client_update_models.dart';
import 'package:licoup/src/frontend/features/settings/ui/client_update_settings_card.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/settings/settings_binding.dart';
import 'package:licoup/src/presentation/settings/settings_intent.dart';

import 'fixtures/settings_binding_fixture.dart';
import 'layout/fixtures/layout_destination_presentation_fixture.dart';

void main() {
  testWidgets('shows three actions, version, and public source address', (
    tester,
  ) async {
    final fixture = _fixture(
      const ClientUpdateStatus(
        phase: ClientUpdatePhase.idle,
        runningVersion: '0.1.0',
        runningReleaseTrack: ReleaseTrack.nightly,
        targetReleaseTrack: ReleaseTrack.nightly,
      ),
    );
    await _pumpCard(tester, fixture, locale: const Locale('zh'));

    expect(find.text('检查更新'), findsOneWidget);
    expect(find.text('下载到本地'), findsOneWidget);
    expect(find.text('更新并重启'), findsOneWidget);
    expect(find.text('0.1.0'), findsOneWidget);
    expect(
      find.byKey(const Key('client-update-release-track')),
      findsOneWidget,
    );
    expect(find.text(kClientUpdateGithubReleasesUrl), findsOneWidget);
    expect(_onPressed(tester, 'client-update-check-github'), isNotNull);
    expect(_onPressed(tester, 'client-update-download-local'), isNull);
    expect(_onPressed(tester, 'client-update-apply-restart'), isNull);
    expect(
      fixture.intents.values.whereType<HydrateClientUpdateIdentity>(),
      hasLength(1),
    );
  });

  testWidgets('nightly selects the stable update track', (tester) async {
    final fixture = _fixture(
      const ClientUpdateStatus(
        phase: ClientUpdatePhase.idle,
        runningVersion: '1.2.0-nightly.3',
        runningReleaseTrack: ReleaseTrack.nightly,
        targetReleaseTrack: ReleaseTrack.nightly,
      ),
    );
    await _pumpCard(tester, fixture);
    await tester.tap(find.text('Stable'));
    await tester.pump();
    expect(
      fixture.intents.values
          .whereType<SetClientUpdateReleaseTrack>()
          .single
          .track,
      ReleaseTrack.stable,
    );
  });

  testWidgets('download enables only for a newer signed release', (
    tester,
  ) async {
    final fixture = _fixture(
      const ClientUpdateStatus(
        phase: ClientUpdatePhase.updateAvailable,
        runningVersion: '1.0.0',
        runningReleaseTrack: ReleaseTrack.stable,
        targetReleaseTrack: ReleaseTrack.stable,
        availableVersion: '1.1.0',
        updateAvailable: true,
        githubReleaseUrl:
            'https://github.com/LicoLand/LicoUp/releases/tag/v1.1.0',
      ),
    );
    await _pumpCard(tester, fixture);
    expect(_onPressed(tester, 'client-update-download-local'), isNotNull);
    expect(_onPressed(tester, 'client-update-apply-restart'), isNull);
    await tester.tap(find.byKey(const Key('client-update-download-local')));
    expect(
      fixture.intents.values.whereType<DownloadClientUpdate>(),
      hasLength(1),
    );
  });

  testWidgets('up-to-date and failed states keep download and apply disabled', (
    tester,
  ) async {
    var fixture = _fixture(
      const ClientUpdateStatus(
        phase: ClientUpdatePhase.upToDate,
        runningVersion: '1.0.0',
        runningReleaseTrack: ReleaseTrack.stable,
        targetReleaseTrack: ReleaseTrack.stable,
      ),
    );
    await _pumpCard(tester, fixture);
    expect(find.byKey(const Key('client-update-release-track')), findsNothing);
    expect(_onPressed(tester, 'client-update-download-local'), isNull);
    expect(_onPressed(tester, 'client-update-apply-restart'), isNull);

    await tester.pumpWidget(const SizedBox.shrink());
    fixture = _fixture(
      const ClientUpdateStatus(
        phase: ClientUpdatePhase.failed,
        runningVersion: '1.0.0',
        runningReleaseTrack: ReleaseTrack.nightly,
        targetReleaseTrack: ReleaseTrack.nightly,
        errorCode: 'client_update_check_failed',
      ),
    );
    await _pumpCard(tester, fixture, locale: const Locale('zh'));
    expect(_onPressed(tester, 'client-update-check-github'), isNotNull);
    expect(_onPressed(tester, 'client-update-download-local'), isNull);
    expect(_onPressed(tester, 'client-update-apply-restart'), isNull);
  });

  testWidgets('verified update dispatches semantic apply intent', (
    tester,
  ) async {
    final fixture = _fixture(
      const ClientUpdateStatus(
        phase: ClientUpdatePhase.verified,
        runningVersion: '1.0.0',
        runningReleaseTrack: ReleaseTrack.stable,
        targetReleaseTrack: ReleaseTrack.stable,
        availableVersion: '1.1.0',
        updateAvailable: true,
      ),
    );
    await _pumpCard(tester, fixture);
    await tester.tap(find.byKey(const Key('client-update-apply-restart')));
    expect(fixture.intents.values.whereType<ApplyClientUpdate>(), hasLength(1));
  });
}

({
  SettingsProjectionFixture source,
  RecordingSettingsIntents intents,
  SettingsBinding binding,
})
_fixture(ClientUpdateStatus status) {
  final source = SettingsProjectionFixture(
    settingsProjectionFixture(clientUpdateStatus: status),
  );
  final intents = RecordingSettingsIntents();
  return (
    source: source,
    intents: intents,
    binding: settingsBindingFixture(source: source, intents: intents),
  );
}

Future<void> _pumpCard(
  WidgetTester tester,
  ({
    SettingsProjectionFixture source,
    RecordingSettingsIntents intents,
    SettingsBinding binding,
  })
  fixture, {
  Locale locale = const Locale('en'),
}) async {
  addTearDown(fixture.source.dispose);
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
      home: Scaffold(body: ClientUpdateSettingsCard(binding: fixture.binding)),
    ),
  );
  await tester.pump();
}

VoidCallback? _onPressed(WidgetTester tester, String key) {
  final widget = tester.widget<ButtonStyleButton>(find.byKey(Key(key)));
  return widget.onPressed;
}
