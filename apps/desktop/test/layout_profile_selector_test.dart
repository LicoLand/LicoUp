import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:licoup/src/application/features/layout/layout_manager.dart';
import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/layout_selection.dart';
import 'package:licoup/src/contracts/presentation/presentation_preferences.dart';
import 'package:licoup/src/frontend/features/settings/ui/layout_profile_selector.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:flutter_test/flutter_test.dart';

import 'layout/layout_host_test_fixtures.dart';
import 'layout/fixtures/layout_destination_presentation_fixture.dart';

void main() {
  testWidgets(
    'renders localized catalog profiles with registry previews on both surfaces',
    (tester) async {
      final runtime = buildFixtureLayoutRuntime();
      final manager = _createManager(
        runtime: runtime,
        repository: _FakePreferencesRepository(preferences: _preferences()),
      );
      addTearDown(manager.dispose);
      await manager.initialize();

      await _pumpSelector(
        tester,
        manager: manager,
        runtime: runtime,
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
        manager: manager,
        runtime: runtime,
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
      expect(
        find.byKey(const Key('fixture-preview-dashboard-desktop')),
        findsNothing,
      );
    },
  );

  testWidgets('enumerates an arbitrary catalog without a profile-count cap', (
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
    final manager = _createManager(
      runtime: runtime,
      repository: _FakePreferencesRepository(preferences: _preferences()),
    );
    addTearDown(manager.dispose);
    await manager.initialize();

    await _pumpSelector(tester, manager: manager, runtime: runtime, width: 860);

    for (final profile in profiles) {
      expect(
        find.byKey(Key('layout-profile-option-${profile.id.value}')),
        findsOneWidget,
      );
    }
  });

  testWidgets('applies selections immediately', (tester) async {
    final runtime = buildFixtureLayoutRuntime();
    final repository = _FakePreferencesRepository(preferences: _preferences());
    final manager = _createManager(runtime: runtime, repository: repository);
    addTearDown(manager.dispose);
    await manager.initialize();
    await _pumpSelector(tester, manager: manager, runtime: runtime);

    await tester.tap(find.byKey(const Key('layout-profile-option-atlas')));
    await tester.pumpAndSettle();
    expect(manager.state.status, LayoutSelectionStatus.stable);
    expect(manager.state.committedId, LayoutProfileId.parse('atlas'));
    expect(
      repository.preferences.layoutProfileId,
      LayoutProfileId.parse('atlas'),
    );
    expect(repository.layoutWriteCount, 1);
    expect(find.byKey(const Key('layout-selector-reset')), findsNothing);
    expect(find.text('Restore system default layout'), findsNothing);
  });

  testWidgets('localizes loading, committing, and bounded persistence errors', (
    tester,
  ) async {
    final runtime = buildFixtureLayoutRuntime();
    final repository = _FakePreferencesRepository(preferences: _preferences());
    final manager = _createManager(runtime: runtime, repository: repository);
    addTearDown(manager.dispose);

    await _pumpSelector(
      tester,
      manager: manager,
      runtime: runtime,
      locale: const Locale('zh'),
    );
    expect(find.byKey(const Key('layout-selector-loading')), findsOneWidget);
    expect(find.text('正在加载布局…'), findsOneWidget);

    await manager.initialize();
    repository.layoutWriteGate = Completer<void>();
    repository.failNextLayoutWrite = true;
    await tester.pump();
    await tester.tap(find.byKey(const Key('layout-profile-option-atlas')));
    await repository.layoutWriteStarted.future;
    await tester.pump();

    expect(find.byKey(const Key('layout-selector-committing')), findsOneWidget);
    expect(find.text('正在保存布局…'), findsOneWidget);
    expect(find.byKey(const Key('layout-selector-reset')), findsNothing);

    repository.layoutWriteGate!.complete();
    await tester.pumpAndSettle();
    expect(manager.state.status, LayoutSelectionStatus.error);
    expect(find.byKey(const Key('layout-selector-error')), findsOneWidget);
    expect(find.text('无法保存布局，请稍后重试。'), findsOneWidget);
  });

  testWidgets('supports keyboard, touch targets, and reduced motion', (
    tester,
  ) async {
    final runtime = buildFixtureLayoutRuntime();
    final manager = _createManager(
      runtime: runtime,
      repository: _FakePreferencesRepository(preferences: _preferences()),
    );
    addTearDown(manager.dispose);
    await manager.initialize();
    await _pumpSelector(
      tester,
      manager: manager,
      runtime: runtime,
      width: 360,
      disableAnimations: true,
    );

    final options = tester.widgetList<AnimatedContainer>(
      find.byType(AnimatedContainer),
    );
    expect(options, isNotEmpty);
    expect(options.every((option) => option.duration == Duration.zero), isTrue);
    expect(
      tester
          .getSize(find.byKey(const Key('layout-profile-option-atlas')))
          .height,
      greaterThanOrEqualTo(48),
    );

    // The Dashboard layout is disabled (not ready), so keyboard traversal
    // skips it and lands on the next selectable option.
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();

    expect(manager.state.status, LayoutSelectionStatus.stable);
    expect(manager.state.committedId, LayoutProfileId.parse('atlas'));
    manager.dispose();
  });

  testWidgets('disposing the selector does not interrupt an in-flight commit', (
    tester,
  ) async {
    final runtime = buildFixtureLayoutRuntime();
    final repository = _FakePreferencesRepository(preferences: _preferences());
    final manager = _createManager(runtime: runtime, repository: repository);
    addTearDown(manager.dispose);
    await manager.initialize();
    await _pumpSelector(tester, manager: manager, runtime: runtime);

    repository.layoutWriteGate = Completer<void>();
    await tester.tap(find.byKey(const Key('layout-profile-option-atlas')));
    await repository.layoutWriteStarted.future;
    await tester.pump();
    expect(manager.state.status, LayoutSelectionStatus.committing);

    await tester.pumpWidget(const SizedBox.shrink());
    expect(manager.state.status, LayoutSelectionStatus.committing);

    repository.layoutWriteGate!.complete();
    await tester.pump();
    expect(manager.state.status, LayoutSelectionStatus.stable);
    expect(manager.state.committedId, LayoutProfileId.parse('atlas'));
    manager.dispose();
  });
}

LayoutManager _createManager({
  required FixtureLayoutRuntime runtime,
  required PresentationPreferencesRepository repository,
}) => LayoutManager(
  catalog: runtime.catalog,
  preferencesRepository: repository,
  canonicalFallback: _preferences(),
  initialEnvironment: LayoutEnvironment.fromConstraints(
    surface: LayoutRuntimeSurface.desktop,
    width: 900,
    height: 800,
    textScale: 1,
    hasPointer: true,
    hasKeyboard: true,
    hasTouch: true,
  ),
);

PresentationPreferences _preferences({LayoutProfileId? layout}) =>
    PresentationPreferences(
      layoutProfileId: layout ?? LayoutProfileId.parse('dashboard'),
      appearancePresetId: 'default-system',
      localePreference: 'system',
    );

Future<void> _pumpSelector(
  WidgetTester tester, {
  required LayoutManager manager,
  required FixtureLayoutRuntime runtime,
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
          child: Align(
            alignment: Alignment.topCenter,
            child: SizedBox(
              width: width,
              child: LayoutProfileSelector(
                manager: manager,
                registry: runtime.registry,
                surface: surface,
              ),
            ),
          ),
        ),
      ),
    ),
  ),
);

final class _FakePreferencesRepository
    implements PresentationPreferencesRepository {
  _FakePreferencesRepository({required this.preferences});

  PresentationPreferences preferences;
  bool failNextLayoutWrite = false;
  int layoutWriteCount = 0;
  Completer<void>? layoutWriteGate;
  Completer<void> layoutWriteStarted = Completer<void>();
  Future<void> _tail = Future<void>.value();

  @override
  Future<PresentationPreferencesLoadResult> load() => _enqueue(
    () async => PresentationPreferencesLoadResult(preferences: preferences),
  );

  @override
  Future<PresentationPreferences> setLayoutProfile(LayoutProfileId id) =>
      _enqueue(() async {
        layoutWriteCount += 1;
        if (!layoutWriteStarted.isCompleted) {
          layoutWriteStarted.complete();
        }
        await layoutWriteGate?.future;
        if (failNextLayoutWrite) {
          failNextLayoutWrite = false;
          throw const PresentationPreferencesRepositoryException(
            PresentationPreferencesRepositoryErrorCode.writeFailed,
          );
        }
        preferences = preferences.copyWith(layoutProfileId: id);
        return preferences;
      });

  @override
  Future<PresentationPreferences> setAppearancePreset(String id) =>
      _enqueue(() async {
        preferences = preferences.copyWith(appearancePresetId: id);
        return preferences;
      });

  @override
  Future<PresentationPreferences> setLocalePreference(String preference) =>
      _enqueue(() async {
        preferences = preferences.copyWith(localePreference: preference);
        return preferences;
      });

  Future<T> _enqueue<T>(Future<T> Function() operation) {
    final completer = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        completer.complete(await operation());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }
}
