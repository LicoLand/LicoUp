import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_client/src/frontend/features/skill_hub/ui/skill_hub_panel_catalog.dart';
import 'package:flutter_client/src/frontend/features/skill_hub/ui/skill_hub_panel_card_support.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Skill Hub category filter is independently interactive', (
    tester,
  ) async {
    final selected = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLicoTheme(platformBrightness: Brightness.dark),
        home: Scaffold(
          body: Column(
            children: [
              SkillCategoryFilter(
                selectedCategory: 'all',
                onChanged: selected.add,
              ),
              const Expanded(child: SkillEmptyPlaceholder()),
            ],
          ),
        ),
      ),
    );

    expect(find.text('No Skills Found'), findsOneWidget);
    await tester.tap(find.text('Public Skills'));
    expect(selected, ['public']);
  });

  test('Skill Hub libraries form a one-way dependency chain', () {
    const root = 'lib/src/frontend/features/skill_hub/ui';
    final panel = File('$root/skill_hub_panel.dart').readAsStringSync();
    final widgets = File(
      '$root/skill_hub_panel_widgets.dart',
    ).readAsStringSync();
    final catalog = File(
      '$root/skill_hub_panel_catalog.dart',
    ).readAsStringSync();
    final cards = File(
      '$root/skill_hub_panel_card_support.dart',
    ).readAsStringSync();
    final picker = File(
      '$root/skill_hub_panel_icon_picker.dart',
    ).readAsStringSync();

    expect(panel, contains("ui/skill_hub_panel_catalog.dart';"));
    expect(panel, contains("ui/skill_hub_panel_widgets.dart';"));
    expect(catalog, contains("ui/skill_hub_panel_card_support.dart';"));
    expect(cards, contains("ui/skill_hub_panel_icon_picker.dart';"));
    for (final leaf in [widgets, catalog, cards, picker]) {
      expect(leaf, isNot(contains('skill_hub_panel.dart')));
    }
    for (final source in [panel, widgets, catalog, cards, picker]) {
      expect(
        source,
        isNot(contains(RegExp(r'^part(?: of)? ', multiLine: true))),
      );
    }
  });
}
