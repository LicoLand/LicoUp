import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/lico_icon_button.dart';
import 'package:licoup/src/frontend/shared/ui/lico_search_capsule.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

void main() {
  testWidgets('search capsule is a pill with icon and hint', (tester) async {
    var taps = 0;
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
          body: Center(
            child: LicoSearchCapsule(
              key: const Key('shared-search'),
              onTap: () => taps += 1,
            ),
          ),
        ),
      ),
    );

    expect(find.text('搜索'), findsOneWidget);
    expect(find.byIcon(Icons.search_rounded), findsOneWidget);
    final box = tester.getSize(find.byKey(const Key('shared-search')));
    expect(box.height, LicoSearchChrome.extent);

    await tester.tap(find.byKey(const Key('shared-search')));
    expect(taps, 1);
  });

  testWidgets('search field uses the same chrome and reports changes', (
    tester,
  ) async {
    final controller = TextEditingController();
    addTearDown(controller.dispose);
    var query = '';
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        supportedLocales: LicoStrings.supportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        theme: buildLicoTheme(platformBrightness: Brightness.dark),
        home: Scaffold(
          body: LicoSearchField(
            key: const Key('shared-search-field'),
            controller: controller,
            query: query,
            hintText: 'Search skills',
            onChanged: (value) => query = value,
          ),
        ),
      ),
    );

    expect(find.text('Search skills'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('shared-search-field')),
      'Alpha',
    );
    expect(query, 'Alpha');
    expect(controller.text, 'Alpha');
  });

  test('capsule height matches the medium icon button', () {
    expect(LicoContentSpacing.item, 16);
    expect(LicoSearchChrome.extent, LicoIconButtonSize.medium.extent);
  });
}
