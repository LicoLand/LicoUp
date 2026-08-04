import 'package:licoup/src/application/controller/client_shell_controller.dart';
import 'package:licoup/src/contracts/appearance/appearance_preset_config.dart';
import 'package:licoup/src/contracts/locale_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('catalog fallback and errors remain bounded presentation state', () {
    final controller = ClientShellController(
      appearancePresetId: 'removed-external',
    );
    addTearDown(controller.dispose);
    final before = controller.presentationListenable.value;

    final fellBack = controller.applyAppearanceCatalog(
      configs: [builtInAppearancePresetConfigs.first],
      directoryPath: '/synthetic/presets',
      errorCodes: const ['external_preset_invalid:1', 'not a stable code'],
    );

    expect(fellBack, isTrue);
    expect(controller.appearancePresetId, AppearancePresetIds.defaultSystem);
    expect(controller.appearancePresetLoadErrors, [
      'external_preset_invalid:1',
    ]);
    expect(controller.presentationListenable.value, before + 1);
  });

  test('every built-in preset including light mode is selectable', () {
    final controller = ClientShellController();
    addTearDown(controller.dispose);

    final pickerIds = controller.selectableAppearancePresetConfigs
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
      controller.appearancePresetConfigs.map((config) => config.id),
      containsAll([
        AppearancePresetIds.defaultSystem,
        AppearancePresetIds.licoSoda,
        AppearancePresetIds.licoSodaLight,
      ]),
    );
    expect(controller.appearancePresetLabel, 'System Default');
    expect(
      controller.applyAppearanceCatalog(
        configs: const [],
        directoryPath: '/synthetic/presets',
      ),
      isFalse,
    );
  });

  test('locale and status presentation change without exposing raw errors', () {
    final controller = ClientShellController(
      localePreference: LocalePreference.english,
    );
    addTearDown(controller.dispose);
    controller.setLocalizedStatus(
      '初始化失败。',
      'Initialization failed.',
      caption: 'Error',
      errorCode: 'client_initialize_failed',
    );

    expect(controller.displayStatusMessage, 'Initialization failed.');
    expect(controller.lastErrorCode, 'client_initialize_failed');
    expect(
      controller.replaceLocalePreference(LocalePreference.chinese),
      isTrue,
    );
    expect(controller.displayStatusMessage, '初始化失败。');
    expect(controller.displayStatusCaption, '错误');

    controller.replaceLastError('raw exception with private detail');
    expect(controller.lastErrorCode, isEmpty);
  });
}
