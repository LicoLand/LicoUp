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
      LayoutProfileId.parse('workbench'),
      LayoutProfileId.parse('workbench'),
    );
    expect(LayoutProfileId.parse('native'), LayoutProfileId.parse('native'));
    expect(LayoutProfileId.parse('classic'), LayoutProfileId.parse('classic'));
    expect(
      [LayoutProfileId.parse('native'), LayoutProfileId.parse('workbench')]
        ..sort(),
      [LayoutProfileId.parse('native'), LayoutProfileId.parse('workbench')],
    );

    for (final invalid in [
      'numeric-2',
      'legacy',
      'workbench-v-two',
      'native-compatibility',
      'Native',
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

  test('platform preferred defaults map Native vs LicoUp fallback', () {
    expect(
      LayoutProfileDefaults.preferredForPlatform(TargetPlatform.macOS),
      LayoutProfileId.parse('native'),
    );
    expect(
      LayoutProfileDefaults.preferredForPlatform(TargetPlatform.windows),
      LayoutProfileId.parse('native'),
    );
    expect(
      LayoutProfileDefaults.preferredForPlatform(TargetPlatform.linux),
      LayoutProfileId.parse('workbench'),
    );
  });

  test('profile descriptor owns validated localized copy', () {
    final descriptor = LayoutProfileDescriptor(
      id: LayoutProfileId.parse('workbench'),
      label: LayoutProfileCopy(english: 'Workbench', chinese: '工作台'),
      description: LayoutProfileCopy(
        english: 'Workbench layout',
        chinese: '工作台布局',
      ),
      styleIdentity: 'spacious-card-workbench',
      isDefault: true,
    );

    expect(descriptor.label.resolve('en'), 'Workbench');
    expect(descriptor.label.resolve('zh'), '工作台');
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
      profileId: LayoutProfileId.parse('workbench'),
      surface: LayoutRuntimeSurface.desktop,
      viewport: LayoutViewportClass.medium,
    );
    final mobileMedium = LayoutVariantKey(
      profileId: LayoutProfileId.parse('workbench'),
      surface: LayoutRuntimeSurface.mobile,
      viewport: LayoutViewportClass.medium,
    );

    expect(desktopMedium, isNot(mobileMedium));
    expect({desktopMedium, mobileMedium}, hasLength(2));
    expect(desktopMedium.compareTo(mobileMedium), lessThan(0));
    expect(desktopMedium.toString(), 'workbench/desktop/medium');
    expect(mobileMedium.toString(), 'workbench/mobile/medium');
  });

  test('selection state rejects impossible candidate and error states', () {
    final previewing = LayoutSelectionState(
      committedId: LayoutProfileId.parse('workbench'),
      effectiveId: LayoutProfileId.parse('native'),
      previewId: LayoutProfileId.parse('native'),
      status: LayoutSelectionStatus.previewing,
      surface: LayoutRuntimeSurface.desktop,
      viewport: LayoutViewportClass.medium,
      operationEpoch: 1,
    );
    expect(
      previewing.effectiveVariantKey.profileId,
      LayoutProfileId.parse('native'),
    );
    expect(
      () => LayoutSelectionState(
        committedId: LayoutProfileId.parse('workbench'),
        effectiveId: LayoutProfileId.parse('native'),
        status: LayoutSelectionStatus.stable,
        surface: LayoutRuntimeSurface.desktop,
        viewport: LayoutViewportClass.medium,
        operationEpoch: 1,
      ),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => LayoutSelectionState(
        committedId: LayoutProfileId.parse('workbench'),
        effectiveId: LayoutProfileId.parse('workbench'),
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
        layoutProfileId: LayoutProfileId.parse('workbench'),
        appearancePresetId: 'default-system',
        localePreference: 'system',
      );
      final decoded = PresentationPreferences.fromJson({
        'schemaVersion': 1,
        'layoutProfileId': 'native',
        'appearancePresetId': 'dark',
        'localePreference': 'zh',
        'transientPanelId': 'runtime-only-value',
        'surface': 'mobile',
        'viewport': 'compact',
      }, fallback: fallback);

      expect(decoded.layoutProfileId, LayoutProfileId.parse('native'));
      expect(decoded.toJson(), {
        'schemaVersion': 1,
        'layoutProfileId': 'native',
        'appearancePresetId': 'dark',
        'localePreference': 'zh',
      });
      expect(decoded.toJson(), isNot(contains('surface')));
      expect(decoded.toJson(), isNot(contains('viewport')));
      expect(decoded.toJson(), isNot(contains('transientPanelId')));
    },
  );
}
