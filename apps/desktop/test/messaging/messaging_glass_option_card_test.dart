import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_glass_option_card.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

void main() {
  testWidgets('showMessagingGlassMenu returns the selected glass action', (
    tester,
  ) async {
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLicoTheme(platformBrightness: Brightness.dark),
        supportedLocales: LicoStrings.supportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        home: Scaffold(
          body: Builder(
            builder: (context) {
              return Center(
                child: TextButton(
                  key: const Key('open-glass-menu'),
                  onPressed: () async {
                    selected = await showMessagingGlassMenu<String>(
                      context: context,
                      globalPosition: const Offset(140, 180),
                      actions: const [
                        MessagingGlassMenuAction(
                          value: 'unpin',
                          label: '取消置顶',
                        ),
                        MessagingGlassMenuAction(
                          value: 'pin',
                          label: '置顶',
                        ),
                      ],
                    );
                  },
                  child: const Text('open'),
                ),
              );
            },
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('open-glass-menu')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('messaging-glass-context-menu')), findsOneWidget);
    expect(find.text('取消置顶'), findsOneWidget);

    await tester.tap(find.text('取消置顶'));
    await tester.pumpAndSettle();

    expect(selected, 'unpin');
    expect(find.byKey(const Key('messaging-glass-context-menu')), findsNothing);
  });

  testWidgets('MessagingGlassOptionCard hosts menu items', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildLicoTheme(platformBrightness: Brightness.dark),
        home: const Scaffold(
          body: Center(
            child: MessagingGlassOptionCard(
              width: 200,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  MessagingGlassMenuSectionHeader(label: '当前对话'),
                  MessagingGlassMenuItem(label: 'Cursor', selected: true),
                  MessagingGlassMenuItem(label: 'Codex'),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('当前对话'), findsOneWidget);
    expect(find.text('Cursor'), findsOneWidget);
    expect(find.byIcon(Icons.check_rounded), findsOneWidget);
  });
}
