import 'package:licoup/src/application/controller/appearance_preference_owner.dart';
import 'package:licoup/src/application/controller/functional_status_runtime.dart';
import 'package:licoup/src/application/controller/locale_preference_owner.dart';
import 'package:licoup/src/contracts/appearance/appearance_preset_config.dart';
import 'package:licoup/src/presentation/environment/locale_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('catalog fallback and errors remain bounded presentation state', () {
    final owner = AppearancePreferenceOwner(presetId: 'removed-external');
    addTearDown(owner.dispose);
    var changes = 0;
    owner.changes.listen((_) => changes += 1);

    final fellBack = owner.applyCatalog(
      configs: [builtInAppearancePresetConfigs.first],
      directoryPath: '/synthetic/presets',
      errorCodes: const ['external_preset_invalid:1', 'not a stable code'],
    );

    expect(fellBack, isTrue);
    expect(owner.presetId, AppearancePresetIds.licoSoda);
    expect(owner.loadErrors, ['external_preset_invalid:1']);
    expect(changes, 1);
  });

  test('every built-in preset including light mode is selectable', () {
    final owner = AppearancePreferenceOwner();
    addTearDown(owner.dispose);

    final pickerIds = owner.selectablePresets
        .map((config) => config.id)
        .toList();
    // A light theme the user cannot choose is not a light theme. Both fixed
    // presets share one brand identity, so each is a legitimate direct choice.
    expect(pickerIds, [
      AppearancePresetIds.licoSoda,
      AppearancePresetIds.licoSodaLight,
    ]);
    expect(AppearancePresetIds.resolutionOnly, isEmpty);
    // Resolution sees the same full built-in catalog.
    expect(
      owner.presets.map((config) => config.id),
      containsAll([
        AppearancePresetIds.defaultSystem,
        AppearancePresetIds.licoSoda,
        AppearancePresetIds.licoSodaLight,
      ]),
    );
    expect(
      findAppearancePresetConfig(owner.presetId, owner.presets).labelFor('en'),
      'LicoUp Dark',
    );
    expect(
      owner.applyCatalog(
        configs: const [],
        directoryPath: '/synthetic/presets',
      ),
      isFalse,
    );
  });

  test('locale and status presentation change without exposing raw errors', () {
    final locale = LocalePreferenceOwner(preference: LocalePreference.english);
    final status = FunctionalStatusRuntime();
    addTearDown(locale.dispose);
    addTearDown(status.dispose);
    status.setLocalized(
      '初始化失败。',
      'Initialization failed.',
      caption: 'Error',
      errorCode: 'client_initialize_failed',
    );

    expect(status.messageEnglish, 'Initialization failed.');
    expect(status.lastErrorCode, 'client_initialize_failed');
    expect(locale.replace(LocalePreference.chinese), isTrue);
    expect(status.messageChinese, '初始化失败。');
    expect(status.caption, 'Error');

    status.replaceLastError('raw exception with private detail');
    expect(status.lastErrorCode, isEmpty);
  });
}
