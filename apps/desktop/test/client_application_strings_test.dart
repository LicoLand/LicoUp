import 'package:licoup/src/application/localization/client_application_strings.dart';
import 'package:licoup/src/contracts/locale_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'application messages resolve without importing frontend localization',
    () {
      final chinese = ClientApplicationStrings.forPreference(
        LocalePreference.chinese,
      );
      final english = ClientApplicationStrings.forPreference(
        LocalePreference.english,
      );

      expect(chinese.defaultPolicy, '默认策略');
      expect(chinese.statusCaptionLabel('Runtime'), '运行时');
      expect(english.defaultPolicy, 'Default Policy');
      expect(english.statusCaptionLabel('Runtime'), 'Runtime');
    },
  );
}
