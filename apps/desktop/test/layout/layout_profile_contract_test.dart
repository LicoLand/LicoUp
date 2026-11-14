import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/layout_selection.dart';
import 'package:licoup/src/contracts/presentation/layout_selection_status.dart';
import 'package:licoup/src/contracts/presentation/layout_style.dart';
import 'package:licoup/src/contracts/presentation/layout_variant.dart';
import 'package:licoup/src/contracts/presentation/presentation_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('layout profile identities are semantic, ordered, and safe', () {
    expect(
      LayoutProfileId.parse('dashboard'),
      LayoutProfileId.parse('dashboard'),
    );
    expect(LayoutProfileId.parse('desktop'), LayoutProfileId.parse('desktop'));
    expect(
      [LayoutProfileId.parse('desktop'), LayoutProfileId.parse('dashboard')]
        ..sort(),
      [LayoutProfileId.parse('dashboard'), LayoutProfileId.parse('desktop')],
    );

    for (final invalid in [
      'numeric-2',
      'legacy',
      'dashboard-v-two',
      'desktop-compatibility',
      'Desktop',
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

  test('profile descriptor owns validated localized copy', () {
    final descriptor = LayoutProfileDescriptor(
      id: LayoutProfileId.parse('dashboard'),
      label: LayoutProfileCopy(english: 'Dashboard', chinese: '仪表盘'),
      description: LayoutProfileCopy(
        english: 'Dashboard layout',
        chinese: '仪表盘布局',
      ),
      styleIdentity: 'dashboard-channel-chat',
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
        'reduceMotion': 'system',
        'loadingEffectId': 'spinner',
        'layoutStyleIds': <String, String>{},
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

  test('layout style identities share the profile id grammar', () {
    expect(LayoutStyleId.parse('plain'), LayoutStyleId.parse('plain'));
    expect([LayoutStyleId.parse('card'), LayoutStyleId.parse('a')]..sort(), [
      LayoutStyleId.parse('a'),
      LayoutStyleId.parse('card'),
    ]);

    for (final invalid in ['3-column', 'Three', 'plain_style', '', '-lead']) {
      expect(
        () => LayoutStyleId.parse(invalid),
        throwsA(isA<FormatException>()),
        reason: invalid,
      );
    }
  });

  test('profile descriptor validates its declared styles', () {
    final plain = LayoutStyleId.parse('plain');
    final card = LayoutStyleId.parse('card');
    LayoutStyleDescriptor style(LayoutStyleId id) => LayoutStyleDescriptor(
      id: id,
      label: LayoutProfileCopy(english: id.value, chinese: id.value),
    );
    LayoutProfileDescriptor descriptor({
      List<LayoutStyleDescriptor>? styles,
      LayoutStyleId? defaultStyleId,
      bool clearDefault = false,
    }) => LayoutProfileDescriptor(
      id: LayoutProfileId.parse('dashboard'),
      label: LayoutProfileCopy(english: 'Dashboard', chinese: '仪表盘'),
      description: LayoutProfileCopy(
        english: 'Dashboard layout',
        chinese: '仪表盘布局',
      ),
      styleIdentity: 'dashboard-channel-chat',
      isDefault: true,
      styles: styles ?? const [],
      defaultStyleId: clearDefault ? null : defaultStyleId,
    );

    expect(
      () => descriptor(
        styles: [style(plain), style(plain)],
        defaultStyleId: plain,
      ),
      throwsA(isA<FormatException>()),
      reason: 'duplicate style ids are rejected',
    );
    expect(
      () => descriptor(styles: [style(card)], defaultStyleId: plain),
      throwsA(isA<FormatException>()),
      reason: 'the default must be one of the declared styles',
    );
    expect(
      () => descriptor(defaultStyleId: plain),
      throwsA(isA<FormatException>()),
      reason: 'a style-less profile declares no default style',
    );
    expect(
      () => descriptor(styles: [style(plain)], clearDefault: true),
      throwsA(isA<FormatException>()),
      reason: 'styled profiles always carry a declared default',
    );

    final styled = descriptor(
      styles: [style(plain), style(card)],
      defaultStyleId: plain,
    );
    expect(styled.defaultStyleId, plain);
    expect(() => styled.styles.add(style(card)), throwsUnsupportedError);
  });

  test('presentation preferences round-trip layout style choices', () {
    final dashboard = LayoutProfileId.parse('dashboard');
    final fallback = PresentationPreferences(
      layoutProfileId: dashboard,
      appearancePresetId: 'default-system',
      localePreference: 'system',
    );

    // An old document without the key loads with an empty map.
    final legacy = PresentationPreferences.fromJson({
      'schemaVersion': 1,
      'layoutProfileId': 'dashboard',
      'appearancePresetId': 'dark',
      'localePreference': 'zh',
    }, fallback: fallback);
    expect(legacy.layoutStyleIds, isEmpty);

    // Malformed entries drop independently without failing the document.
    final decoded = PresentationPreferences.fromJson({
      'schemaVersion': 1,
      'layoutProfileId': 'dashboard',
      'appearancePresetId': 'dark',
      'localePreference': 'zh',
      'layoutStyleIds': {
        'dashboard': 'card',
        'Bad Profile': 'wide',
        'atlas': 42,
        'desktop': 'Invalid Case',
      },
    }, fallback: fallback);
    expect(decoded.layoutStyleIds, {dashboard: LayoutStyleId.parse('card')});

    // A canonical document round-trips its style map byte-for-byte.
    final roundTripped = PresentationPreferences.fromJson(
      decoded.toJson(),
      fallback: fallback,
    );
    expect(roundTripped, decoded);

    // A fresh document writes and reads back the same selections.
    final stored = fallback.copyWith(
      layoutStyleIds: {dashboard: LayoutStyleId.parse('plain')},
    );
    expect(
      PresentationPreferences.fromJson(
        stored.toJson(),
        fallback: fallback,
      ).layoutStyleIds[dashboard],
      LayoutStyleId.parse('plain'),
    );
  });
}
