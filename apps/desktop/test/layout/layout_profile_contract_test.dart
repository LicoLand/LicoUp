import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/layout_profile.dart';
import 'package:flutter_client/src/contracts/presentation/layout_selection.dart';
import 'package:flutter_client/src/contracts/presentation/layout_variant.dart';
import 'package:flutter_client/src/contracts/presentation/presentation_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('layout profile identities are semantic, ordered, and safe', () {
    expect(LayoutProfileId.parse('workbench'), LayoutProfileId.workbench);
    expect(LayoutProfileId.parse('studio'), LayoutProfileId.studio);
    expect([LayoutProfileId.studio, LayoutProfileId.workbench]..sort(), [
      LayoutProfileId.studio,
      LayoutProfileId.workbench,
    ]);

    for (final invalid in [
      'layout-1',
      'legacy',
      'workbench-v-two',
      'studio-compatibility',
      'Studio',
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

  test('profile descriptor uses validated localization metadata keys', () {
    final descriptor = LayoutProfileDescriptor(
      id: LayoutProfileId.workbench,
      labelKey: 'layout.profile.workbench.label',
      descriptionKey: 'layout.profile.workbench.description',
      styleIdentity: 'spacious-card-workbench',
      isDefault: true,
    );

    expect(descriptor.labelKey, 'layout.profile.workbench.label');
    expect(descriptor.revision, 1);
    expect(
      () => LayoutProfileDescriptor(
        id: LayoutProfileId.workbench,
        labelKey: 'User visible label',
        descriptionKey: 'layout.profile.workbench.description',
        styleIdentity: 'spacious-card-workbench',
        isDefault: true,
      ),
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
    const desktopMedium = LayoutVariantKey(
      profileId: LayoutProfileId.workbench,
      surface: LayoutRuntimeSurface.desktop,
      viewport: LayoutViewportClass.medium,
    );
    const mobileMedium = LayoutVariantKey(
      profileId: LayoutProfileId.workbench,
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
      committedId: LayoutProfileId.workbench,
      effectiveId: LayoutProfileId.studio,
      previewId: LayoutProfileId.studio,
      status: LayoutSelectionStatus.previewing,
      surface: LayoutRuntimeSurface.desktop,
      viewport: LayoutViewportClass.medium,
      operationEpoch: 1,
    );
    expect(previewing.effectiveVariantKey.profileId, LayoutProfileId.studio);
    expect(
      () => LayoutSelectionState(
        committedId: LayoutProfileId.workbench,
        effectiveId: LayoutProfileId.studio,
        status: LayoutSelectionStatus.stable,
        surface: LayoutRuntimeSurface.desktop,
        viewport: LayoutViewportClass.medium,
        operationEpoch: 1,
      ),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => LayoutSelectionState(
        committedId: LayoutProfileId.workbench,
        effectiveId: LayoutProfileId.workbench,
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
        layoutProfileId: LayoutProfileId.workbench,
        appearancePresetId: 'default-system',
        localePreference: 'system',
      );
      final decoded = PresentationPreferences.fromJson({
        'schemaVersion': 1,
        'layoutProfileId': 'studio',
        'appearancePresetId': 'dark',
        'localePreference': 'zh',
        'shellLayoutId': 'retired-value',
        'surface': 'mobile',
        'viewport': 'compact',
      }, fallback: fallback);

      expect(decoded.layoutProfileId, LayoutProfileId.studio);
      expect(decoded.toJson(), {
        'schemaVersion': 1,
        'layoutProfileId': 'studio',
        'appearancePresetId': 'dark',
        'localePreference': 'zh',
      });
      expect(decoded.toJson(), isNot(contains('surface')));
      expect(decoded.toJson(), isNot(contains('viewport')));
      expect(decoded.toJson(), isNot(contains('shellLayoutId')));
    },
  );
}
