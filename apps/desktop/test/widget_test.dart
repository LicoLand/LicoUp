import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/locale_preferences.dart';
import 'package:licoup/src/frontend/locale/locale_projection_adapter.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/presentation/shell/shell_projection.dart';

void main() {
  test('app sections are the LicoUp client modules', () {
    expect(ClientSection.values, [
      ClientSection.agents,
      ClientSection.monitoring,
      ClientSection.skillHub,
      ClientSection.pluginManagement,
      ClientSection.mobileRelay,
      ClientSection.models,
      ClientSection.settings,
      ClientSection.agentHub,
    ]);
  });

  test('client locale resolves from system language', () {
    expect(LicoStrings.resolve(const Locale('zh', 'CN')).languageCode, 'zh');
    expect(LicoStrings.resolve(const Locale('zh', 'TW')).languageCode, 'zh');
    expect(LicoStrings.resolve(const Locale('en', 'US')).languageCode, 'en');
    expect(LicoStrings.resolve(const Locale('fr', 'FR')).languageCode, 'en');
    expect(
      LicoStrings.resolvePreferred(const [
        Locale('fr'),
        Locale('zh'),
      ]).languageCode,
      'zh',
    );
    expect(
      LicoStrings.resolvePreferred(const [
        Locale('en'),
        Locale('zh'),
      ]).languageCode,
      'en',
    );
  });

  test('locale preference maps to system or explicit app locale', () {
    expect(LocalePreference.normalize(''), LocalePreference.system);
    expect(LocalePreference.normalize('zh'), LocalePreference.chinese);
    expect(LocalePreference.normalize('en'), LocalePreference.english);
    expect(LocalePreference.normalize('fr'), LocalePreference.system);
    expect(LicoStrings.localeForPreference('system'), isNull);
    expect(LicoStrings.localeForPreference('zh')?.languageCode, 'zh');
    expect(LicoStrings.localeForPreference('en')?.languageCode, 'en');
    expect(localeFromProjection(const LocaleProjection('system')), isNull);
    expect(
      localeFromProjection(const LocaleProjection('zh'))?.languageCode,
      'zh',
    );
  });
}
