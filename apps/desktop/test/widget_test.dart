import 'dart:ui';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_client/src/l10n/lico_strings.dart';
import 'package:flutter_client/src/models/future_client_models.dart';

void main() {
  test('app sections are the future client modules', () {
    expect(FutureClientSection.values, [
      FutureClientSection.agents,
      FutureClientSection.mcpPlugins,
      FutureClientSection.skillHub,
      FutureClientSection.modelForwarding,
      FutureClientSection.localRuntime,
      FutureClientSection.mobileRelay,
      FutureClientSection.activity,
      FutureClientSection.settings,
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
}
