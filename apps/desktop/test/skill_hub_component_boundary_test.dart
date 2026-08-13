import 'dart:io';

import 'package:flutter/material.dart';
import 'package:licoup/src/frontend/features/skill_hub/ui/skill_hub_panel_catalog.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/lico_empty_state.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
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
              Expanded(
                child: Builder(
                  builder: (context) => LicoEmptyState(
                    icon: Icons.extension_outlined,
                    iconSize: 64,
                    title: LicoStrings.of(context).noSkillsFound,
                    message: LicoStrings.of(context).refreshSkillsHint,
                    padding: const EdgeInsets.all(32),
                  ),
                ),
              ),
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
    expect(catalog, contains("ui/skill_hub_panel_card_support.dart';"));
    expect(catalog, contains("shared/ui/lico_empty_state.dart';"));
    expect(cards, contains("ui/skill_hub_panel_icon_picker.dart';"));
    for (final leaf in [catalog, cards, picker]) {
      expect(leaf, isNot(contains('skill_hub_panel.dart')));
    }
    for (final source in [panel, catalog, cards, picker]) {
      expect(
        source,
        isNot(contains(RegExp(r'^part(?: of)? ', multiLine: true))),
      );
    }
  });
}
