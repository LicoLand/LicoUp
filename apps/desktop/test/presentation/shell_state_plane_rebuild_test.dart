import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/app.dart';
import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/composition/client_app_composition.dart';
import 'package:licoup/src/contracts/appearance/appearance_preset_config.dart';
import 'package:licoup/src/contracts/locale_preferences.dart';

void main() {
  testWidgets('shell state planes rebuild only their owning app adapter', (
    tester,
  ) async {
    final controller = ClientController();
    final composition = ClientAppComposition(controller: controller);

    await tester.pumpWidget(
      LicoApp(
        compositionFactory: () => composition,
        initializeController: false,
        homeBuilder: (_, _, _) => const SizedBox(),
      ),
    );
    await tester.pump();
    final initial = tester.widget<MaterialApp>(find.byType(MaterialApp));

    controller.statusMessage = 'Focused status';
    await tester.pump();
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)), same(initial));

    controller.localePreference = LocalePreference.chinese;
    await tester.pump();
    final localized = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(localized, isNot(same(initial)));
    expect(localized.locale, const Locale('zh'));

    controller.appearancePresetId = AppearancePresetIds.licoSodaLight;
    await tester.pump();
    final themed = tester.widget<MaterialApp>(find.byType(MaterialApp));
    expect(themed, isNot(same(localized)));
    expect(themed.themeMode, ThemeMode.light);

    await tester.runAsync(composition.dispose);
    await tester.pumpWidget(const SizedBox());
  });
}
