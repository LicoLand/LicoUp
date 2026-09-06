import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/frontend/features/settings/ui/layout_profile_selector.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_registry.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';
import 'package:licoup/src/presentation/settings/settings_binding.dart';
import 'package:licoup/src/presentation/settings/settings_intent.dart';

import 'fixtures/settings_binding_fixture.dart';
import 'layout/layout_host_test_fixtures.dart';
import 'layout/fixtures/layout_destination_presentation_fixture.dart';

void main() {
  testWidgets('renders localized registry previews on both surfaces', (
    tester,
  ) async {
    final registry = buildFixtureLayoutRuntime().registry;
    final source = SettingsProjectionFixture(settingsProjectionFixture());
    final binding = settingsBindingFixture(source: source);
    addTearDown(source.dispose);

    await _pumpSelector(
      tester,
      binding: binding,
      registry: registry,
      surface: LayoutRuntimeSurface.desktop,
      locale: const Locale('zh'),
    );
    expect(
      find.byKey(const ValueKey<String>('layout-profile-selector')),
      findsOneWidget,
    );
    expect(find.text('工作台'), findsOneWidget);
    expect(find.text('图集'), findsOneWidget);
    expect(
      find.byKey(const Key('fixture-preview-dashboard-desktop')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('fixture-preview-atlas-desktop')),
      findsOneWidget,
    );

    await _pumpSelector(
      tester,
      binding: binding,
      registry: registry,
      surface: LayoutRuntimeSurface.mobile,
      locale: const Locale('zh'),
    );
    expect(
      find.byKey(const Key('fixture-preview-dashboard-mobile')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('fixture-preview-atlas-mobile')),
      findsOneWidget,
    );
  });

  testWidgets('dispatches semantic selection without owning persistence', (
    tester,
  ) async {
    final registry = buildFixtureLayoutRuntime().registry;
    final source = SettingsProjectionFixture(settingsProjectionFixture());
    final intents = RecordingSettingsIntents();
    final binding = settingsBindingFixture(source: source, intents: intents);
    addTearDown(source.dispose);
    await _pumpSelector(tester, binding: binding, registry: registry);

    await tester.tap(find.byKey(const Key('layout-profile-option-atlas')));
    await tester.pump();
    expect(intents.values, hasLength(1));
    expect(intents.values.single, isA<SetLayoutPreference>());
    expect((intents.values.single as SetLayoutPreference).profileId, 'atlas');
  });

  testWidgets('enumerates every profile in an arbitrary catalog', (
    tester,
  ) async {
    final profiles = <LayoutProfileDescriptor>[
      ...fixtureLayoutDescriptors(),
      for (final id in ['canvas', 'focus', 'journal', 'matrix', 'orbit'])
        LayoutProfileDescriptor(
          id: LayoutProfileId.parse(id),
          label: LayoutProfileCopy(english: id, chinese: '布局$id'),
          description: LayoutProfileCopy(
            english: '$id fixture layout',
            chinese: '布局 $id 的测试说明',
          ),
          styleIdentity: 'fixture-$id',
          isDefault: false,
        ),
    ];
    final runtime = buildFixtureLayoutRuntime(profiles: profiles);
    final source = SettingsProjectionFixture(
      settingsProjectionFixture(
        layoutChoices: [
          for (final profile in profiles)
            PresentationChoice(
              id: profile.id.value,
              label: profile.label.english,
              selected: profile.id.value == 'dashboard',
              enabled: profile.id.value != 'dashboard',
            ),
        ],
      ),
    );
    final binding = settingsBindingFixture(source: source);
    addTearDown(source.dispose);
    await _pumpSelector(
      tester,
      binding: binding,
      registry: runtime.registry,
      width: 860,
    );

    for (final profile in profiles) {
      expect(
        find.byKey(Key('layout-profile-option-${profile.id.value}')),
        findsOneWidget,
      );
    }
  });

  testWidgets('localizes committing and persistence failure states', (
    tester,
  ) async {
    final registry = buildFixtureLayoutRuntime().registry;
    final source = SettingsProjectionFixture(
      settingsProjectionFixture(layoutPhase: PresentationPhase.applying),
    );
    final binding = settingsBindingFixture(source: source);
    addTearDown(source.dispose);
    await _pumpSelector(
      tester,
      binding: binding,
      registry: registry,
      locale: const Locale('zh'),
    );
    expect(find.text('正在保存布局…'), findsOneWidget);

    source.publish(
      settingsProjectionFixture(
        layoutPhase: PresentationPhase.failed,
        layoutFailureReasonCode: 'persistenceFailed',
        notice: const PresentationNotice(
          id: 'settings-layout-failure',
          title: 'Settings action failed',
          message: 'Review the action and try again.',
          severity: PresentationNoticeSeverity.error,
          reasonCode: 'persistenceFailed',
        ),
      ),
    );
    await tester.pump();
    expect(find.text('无法保存布局，请稍后重试。'), findsOneWidget);
  });

  testWidgets('shows loading and supports keyboard with reduced motion', (
    tester,
  ) async {
    final registry = buildFixtureLayoutRuntime().registry;
    final source = SettingsProjectionFixture(
      settingsProjectionFixture(layoutPhase: PresentationPhase.loading),
    );
    final intents = RecordingSettingsIntents();
    final binding = settingsBindingFixture(source: source, intents: intents);
    addTearDown(source.dispose);
    await _pumpSelector(
      tester,
      binding: binding,
      registry: registry,
      width: 360,
      disableAnimations: true,
      locale: const Locale('zh'),
    );
    expect(find.byKey(const Key('layout-selector-loading')), findsOneWidget);

    source.publish(settingsProjectionFixture());
    await tester.pump();
    final options = tester.widgetList<AnimatedContainer>(
      find.byType(AnimatedContainer),
    );
    expect(options, isNotEmpty);
    expect(options.every((option) => option.duration == Duration.zero), isTrue);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(intents.values.whereType<SetLayoutPreference>(), isNotEmpty);
  });
}

Future<void> _pumpSelector(
  WidgetTester tester, {
  required SettingsBinding binding,
  required LayoutRegistry registry,
  LayoutRuntimeSurface surface = LayoutRuntimeSurface.desktop,
  Locale locale = const Locale('en'),
  double width = 860,
  bool disableAnimations = false,
}) => tester.pumpWidget(
  MaterialApp(
    builder: (context, child) => FixtureLayoutPresentationScope(child: child!),
    locale: locale,
    supportedLocales: LicoStrings.supportedLocales,
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
    ],
    theme: buildLicoTheme(),
    home: Scaffold(
      body: MediaQuery(
        data: MediaQueryData(disableAnimations: disableAnimations),
        child: SingleChildScrollView(
          child: SizedBox(
            width: width,
            child: LayoutProfileSelector(
              binding: binding,
              registry: registry,
              surface: surface,
            ),
          ),
        ),
      ),
    ),
  ),
);
