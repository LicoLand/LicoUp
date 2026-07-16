import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_client/src/frontend/features/settings/ui/settings_panel_widgets.dart';
import 'package:flutter_client/src/frontend/layout/layout_destination_presentation.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';
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
                DropdownMenuItem(value: 'system', child: Text('System')),
                DropdownMenuItem(value: 'en', child: Text('English')),
              ],
              onChanged: (_) {},
            ),
          ),
        ),
      ),
    );

    expect(find.text('Language'), findsOneWidget);
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pump();
    expect(find.text('English'), findsOneWidget);
  });

  test('settings component library does not depend on panel internals', () {
    const root = 'lib/src/frontend/features/settings/ui';
    final panel = File('$root/settings_panel.dart').readAsStringSync();
    final widgets = File(
      '$root/settings_panel_widgets.dart',
    ).readAsStringSync();

    expect(panel, contains("ui/settings_panel_widgets.dart';"));
    expect(widgets, isNot(contains('settings_panel.dart')));
    for (final source in [panel, widgets]) {
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
  EdgeInsetsGeometry get contentPadding => EdgeInsets.zero;
  @override
  EdgeInsetsGeometry get indexPadding => EdgeInsets.zero;
  @override
  EdgeInsetsGeometry get rowPadding => EdgeInsets.zero;
  @override
  EdgeInsetsGeometry get sectionHeaderPadding => EdgeInsets.zero;
  @override
  EdgeInsetsGeometry get selectorActionPadding => EdgeInsets.zero;
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
