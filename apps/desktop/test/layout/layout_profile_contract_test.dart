import 'package:flutter/foundation.dart';
import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/layout_selection.dart';
import 'package:licoup/src/contracts/presentation/layout_variant.dart';
import 'package:licoup/src/contracts/presentation/presentation_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('layout profile identities are semantic, ordered, and safe', () {
    expect(
      LayoutProfileId.parse('dashboard'),
      LayoutProfileId.parse('dashboard'),
    );
    expect(
      LayoutProfileId.parse('messaging'),
      LayoutProfileId.parse('messaging'),
    );
    expect(
      [LayoutProfileId.parse('messaging'), LayoutProfileId.parse('dashboard')]
        ..sort(),
      [LayoutProfileId.parse('dashboard'), LayoutProfileId.parse('messaging')],
    );

    for (final invalid in [
      'numeric-2',
      'legacy',
      'dashboard-v-two',
      'messaging-compatibility',
      'Messaging',
    ]) {
      Object? failure;
      try {
        LayoutProfileId.parse(invalid);
      } catch (error) {
        failure = error;
      }
      expect(failure, isA<FormatException>());
      expect('$failure', isNot(contains(invalid)));
    }
  });

  test('platform preferred defaults map Default vs Dashboard fallback', () {
    expect(
      LayoutProfileDefaults.preferredForPlatform(TargetPlatform.macOS),
      LayoutProfileId.parse('messaging'),
    );
    expect(
      LayoutProfileDefaults.preferredForPlatform(TargetPlatform.windows),
      LayoutProfileId.parse('messaging'),
    );
    expect(
      LayoutProfileDefaults.preferredForPlatform(TargetPlatform.linux),
      LayoutProfileId.parse('dashboard'),
    );
  });

  test('profile descriptor owns validated localized copy', () {
    final descriptor = LayoutProfileDescriptor(
      id: LayoutProfileId.parse('dashboard'),
      label: LayoutProfileCopy(english: 'Dashboard', chinese: '仪表盘'),
      description: LayoutProfileCopy(
        english: 'Dashboard layout',
        chinese: '仪表盘布局',
      ),
      styleIdentity: 'spacious-card-dashboard',
      isDefault: true,
    );

    expect(descriptor.label.resolve('en'), 'Dashboard');
    expect(descriptor.label.resolve('zh'), '仪表盘');
    expect(descriptor.revision, 1);
    expect(
      () => LayoutProfileCopy(english: 'Valid', chinese: '\n'),
      throwsA(isA<FormatException>()),
    );
  });

  test('surface-bounded viewport classification never crosses surfaces', () {
    expect(
      LayoutViewportPolicy.supportedFor(LayoutRuntimeSurface.desktop),
      const {LayoutViewportClass.medium, LayoutViewportClass.expanded},
    );
    expect(
      LayoutViewportPolicy.supportedFor(LayoutRuntimeSurface.mobile),
      const {LayoutViewportClass.compact, LayoutViewportClass.medium},
    );
    expect(
      LayoutViewportPolicy.classify(
        surface: LayoutRuntimeSurface.desktop,
        width: 320,
      ),
      LayoutViewportClass.medium,
    );
    expect(
      LayoutViewportPolicy.classify(
        surface: LayoutRuntimeSurface.desktop,
        width: 1400,
      ),
      LayoutViewportClass.expanded,
    );
    expect(
      LayoutViewportPolicy.classify(
        surface: LayoutRuntimeSurface.mobile,
        width: 1400,
      ),
      LayoutViewportClass.medium,
    );
    expect(
      LayoutViewportPolicy.classify(
        surface: LayoutRuntimeSurface.mobile,
        width: 390,
      ),
      LayoutViewportClass.compact,
    );
  });

  test('layout environment validates bounded public metrics', () {
    final environment = LayoutEnvironment.fromConstraints(
      surface: LayoutRuntimeSurface.mobile,
      width: 700,
      height: 900,
      textScale: 1.25,
      safeInsets: LayoutInsets(top: 24),
      keyboardInset: 320,
      hasTouch: true,
      reducedMotion: true,
    );

    expect(environment.viewport, LayoutViewportClass.medium);
    expect(
      environment,
      LayoutEnvironment.fromConstraints(
        surface: LayoutRuntimeSurface.mobile,
        width: 700,
        height: 900,
        textScale: 1.25,
        safeInsets: LayoutInsets(top: 24),
        keyboardInset: 320,
        hasTouch: true,
        reducedMotion: true,
      ),
    );
    expect(
      () => LayoutEnvironment.fromConstraints(
        surface: LayoutRuntimeSurface.desktop,
        width: double.nan,
        height: 800,
        textScale: 1,
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('surface is part of deterministic variant identity and ordering', () {
    final desktopMedium = LayoutVariantKey(
      profileId: LayoutProfileId.parse('dashboard'),
      surface: LayoutRuntimeSurface.desktop,
      viewport: LayoutViewportClass.medium,
    );
    final mobileMedium = LayoutVariantKey(
      profileId: LayoutProfileId.parse('dashboard'),
      surface: LayoutRuntimeSurface.mobile,
      viewport: LayoutViewportClass.medium,
    );

    expect(desktopMedium, isNot(mobileMedium));
    expect({desktopMedium, mobileMedium}, hasLength(2));
    expect(desktopMedium.compareTo(mobileMedium), lessThan(0));
    expect(desktopMedium.toString(), 'dashboard/desktop/medium');
    expect(mobileMedium.toString(), 'dashboard/mobile/medium');
  });

  test('selection state rejects impossible candidate and error states', () {
    final committing = LayoutSelectionState(
      committedId: LayoutProfileId.parse('dashboard'),
      effectiveId: LayoutProfileId.parse('atlas'),
      status: LayoutSelectionStatus.committing,
      surface: LayoutRuntimeSurface.desktop,
      viewport: LayoutViewportClass.medium,
      operationEpoch: 1,
    );
    expect(
      committing.effectiveVariantKey.profileId,
      LayoutProfileId.parse('atlas'),
    );
    expect(
      () => LayoutSelectionState(
        committedId: LayoutProfileId.parse('dashboard'),
        effectiveId: LayoutProfileId.parse('atlas'),
        status: LayoutSelectionStatus.stable,
        surface: LayoutRuntimeSurface.desktop,
        viewport: LayoutViewportClass.medium,
        operationEpoch: 1,
      ),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => LayoutSelectionState(
        committedId: LayoutProfileId.parse('dashboard'),
        effectiveId: LayoutProfileId.parse('dashboard'),
        status: LayoutSelectionStatus.error,
        surface: LayoutRuntimeSurface.desktop,
        viewport: LayoutViewportClass.medium,
        operationEpoch: 1,
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test(
    'presentation preferences persist only semantic presentation fields',
    () {
      final fallback = PresentationPreferences(
        layoutProfileId: LayoutProfileId.parse('dashboard'),
        appearancePresetId: 'default-system',
        localePreference: 'system',
      );
      final decoded = PresentationPreferences.fromJson({
        'schemaVersion': 1,
        'layoutProfileId': 'atlas',
        'appearancePresetId': 'dark',
        'localePreference': 'zh',
        'transientPanelId': 'runtime-only-value',
        'surface': 'mobile',
        'viewport': 'compact',
      }, fallback: fallback);

      expect(decoded.layoutProfileId, LayoutProfileId.parse('atlas'));
      expect(decoded.toJson(), {
        'schemaVersion': 1,
        'layoutProfileId': 'atlas',
        'appearancePresetId': 'dark',
        'localePreference': 'zh',
      });
      expect(decoded.toJson(), isNot(contains('surface')));
      expect(decoded.toJson(), isNot(contains('viewport')));
      expect(decoded.toJson(), isNot(contains('transientPanelId')));
      expect(
        () => PresentationPreferences.fromJson({
          'layoutProfileId': 'atlas',
          'appearancePresetId': 'dark',
          'localePreference': 'zh',
        }, fallback: fallback),
        throwsA(isA<FormatException>()),
      );
    },
  );
}
