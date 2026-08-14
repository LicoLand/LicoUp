import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:licoup/src/frontend/features/settings/ui/settings_panel_widgets.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('settings dropdown renders independently from the panel', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLicoTheme(platformBrightness: Brightness.dark),
        home: Scaffold(
          body: LayoutDestinationPresentationScope(
            settings: const _TestSettingsPresentation(),
            child: SettingsDropdownRow<String>(
              icon: Icons.language_outlined,
              title: 'Language',
              value: 'system',
              items: const [
                SettingsDropdownItem(value: 'system', label: 'System'),
                SettingsDropdownItem(value: 'en', label: 'English'),
              ],
              onSelected: (_) {},
            ),
          ),
        ),
      ),
    );

    expect(find.text('Language'), findsOneWidget);
    expect(find.byType(SettingsDropdownList<String>), findsOneWidget);
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pump();
    expect(find.text('English'), findsOneWidget);
  });

  testWidgets('locked dropdown does not change selection on tap', (
    tester,
  ) async {
    var selected = 'lico-soda';

    await tester.pumpWidget(
      MaterialApp(
        theme: buildLicoTheme(platformBrightness: Brightness.dark),
        home: Scaffold(
          body: LayoutDestinationPresentationScope(
            settings: const _TestSettingsPresentation(),
            child: StatefulBuilder(
              builder: (context, setState) {
                return SettingsDropdownList<String>(
                  key: const Key('settings-appearance-dropdown'),
                  value: selected,
                  locked: true,
                  items: const [
                    SettingsDropdownItem(
                      value: 'lico-soda',
                      label: 'LicoUp Dark',
                    ),
                    SettingsDropdownItem(
                      value: 'lico-soda-light',
                      label: 'LicoUp Light',
                    ),
                  ],
                  onSelected: (value) => setState(() => selected = value),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('LicoUp Dark'), findsOneWidget);
    await tester.tap(find.byKey(const Key('settings-appearance-dropdown')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('LicoUp Light'), findsNothing);
    expect(selected, 'lico-soda');
  });

  testWidgets('locale dropdown invokes the locale callback', (tester) async {
    var preference = 'zh';

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('zh'),
        supportedLocales: LicoStrings.supportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        theme: buildLicoTheme(platformBrightness: Brightness.dark),
        home: Scaffold(
          body: LayoutDestinationPresentationScope(
            settings: const _TestSettingsPresentation(),
            child: StatefulBuilder(
              builder: (context, setState) {
                return SettingsDropdownRow<String>(
                  dropdownKey: const Key('settings-locale-dropdown'),
                  icon: Icons.language_outlined,
                  title: '语言',
                  value: preference,
                  items: const [
                    SettingsDropdownItem(
                      value: 'system',
                      label: '系统',
                      key: Key('settings-locale-system'),
                    ),
                    SettingsDropdownItem(
                      value: 'zh',
                      label: '中文',
                      key: Key('settings-locale-zh'),
                    ),
                    SettingsDropdownItem(
                      value: 'en',
                      label: 'English',
                      key: Key('settings-locale-en'),
                    ),
                  ],
                  onSelected: (value) => setState(() => preference = value),
                );
              },
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.byType(SettingsDropdownList<String>), findsOneWidget);
    expect(find.byKey(const Key('settings-locale-list')), findsNothing);
    expect(find.byKey(const Key('settings-locale-toggle')), findsNothing);
    await tester.tap(find.byKey(const Key('settings-locale-dropdown')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byKey(const Key('settings-locale-en')).last);
    await tester.pump();
    expect(preference, 'en');
  });

  test('settings component library does not depend on panel internals', () {
    const root = 'lib/src/frontend/features/settings/ui';
    final panel = File('$root/settings_panel.dart').readAsStringSync();
    final widgets = File(
      '$root/settings_panel_widgets.dart',
    ).readAsStringSync();
    final dropdown = File(
      '$root/settings_dropdown_list.dart',
    ).readAsStringSync();

    expect(panel, contains("ui/settings_panel_widgets.dart';"));
    expect(widgets, isNot(contains('settings_panel.dart')));
    expect(dropdown, isNot(contains('settings_panel.dart')));
    expect(dropdown, isNot(contains('IgnorePointer')));
    for (final source in [panel, widgets, dropdown]) {
      expect(
        source,
        isNot(contains(RegExp(r'^part(?: of)? ', multiLine: true))),
      );
    }
  });
}

final class _TestSettingsPresentation implements LayoutSettingsPresentation {
  const _TestSettingsPresentation();

  @override
  bool get indexHostedByNavigation => false;

  @override
  EdgeInsetsGeometry get contentPadding => EdgeInsets.zero;
  @override
  EdgeInsetsGeometry get indexPadding => EdgeInsets.zero;
  @override
  EdgeInsetsGeometry get rowPadding => EdgeInsets.zero;
  @override
  EdgeInsetsGeometry get sectionHeaderPadding => EdgeInsets.zero;
  @override
  EdgeInsetsGeometry get selectorGridPadding => EdgeInsets.zero;

  @override
  Widget frameIndex(
    BuildContext context, {
    required bool hovered,
    required Widget child,
  }) => child;

  @override
  Widget frameSection(
    BuildContext context, {
    required Key key,
    required Widget child,
  }) => KeyedSubtree(key: key, child: child);

  @override
  Widget frameSelector(BuildContext context, {required Widget child}) => child;
}
