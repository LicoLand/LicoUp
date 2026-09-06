import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_status_capsule_toast.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/lico_activity_animations.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

void main() {
  const toastKey = Key('messaging-status-capsule-toast');
  const iconKey = Key('messaging-status-capsule-icon');
  const pulseKey = Key('messaging-status-capsule-pulse');

  Future<void> pumpToastLauncher(
    WidgetTester tester, {
    required String message,
    Locale locale = const Locale('en'),
    bool pulse = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        supportedLocales: LicoStrings.supportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        theme: buildLicoTheme(platformBrightness: Brightness.dark),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                key: const Key('show-toast'),
                onPressed: () => showMessagingStatusCapsuleToast(
                  context,
                  message: message,
                  pulse: pulse,
                ),
                child: const Text('Show'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byKey(const Key('show-toast')));
    await tester.pump();
  }

  testWidgets(
    'copy confirmation appears as a capsule toast with the l10n text',
    (tester) async {
      final strings = LicoStrings.forLocale(const Locale('en'));
      await pumpToastLauncher(
        tester,
        message: strings.conversationMessageCopied,
      );
      // Entrance animation completes; the capsule is fully visible.
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('Message copied'), findsOneWidget);
      expect(find.byKey(toastKey), findsOneWidget);
      // The copied confirmation uses the capsule chrome: no SnackBar vehicle.
      expect(find.byType(SnackBar), findsNothing);
      expect(find.byKey(iconKey), findsOneWidget);
      final icon = tester.widget<Icon>(find.byKey(iconKey));
      expect(icon.icon, Icons.check_circle_rounded);
      final pulse = tester.widget<LicoTopEdgePulse>(find.byKey(pulseKey));
      expect(pulse.enabled, isFalse);

      // The capsule floats bottom-anchored, clear of the flow's bottom edge.
      final capsuleRect = tester.getRect(find.byKey(toastKey));
      final surfaceHeight =
          tester.view.physicalSize.height / tester.view.devicePixelRatio;
      expect(
        capsuleRect.bottom,
        closeTo(surfaceHeight - 16, 1),
        reason: 'bottom-anchored with the shared 16px snackbar margin',
      );

      // Auto-dismisses shortly after (~2s) without further interaction.
      await tester.pump(const Duration(milliseconds: 2000));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump();
      expect(find.byKey(toastKey), findsNothing);
      expect(find.text('Message copied'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('conversation-id copy keeps its l10n text on the capsule', (
    tester,
  ) async {
    await pumpToastLauncher(
      tester,
      message: LicoStrings.forLocale(const Locale('en')).conversationIdCopied,
    );
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('Conversation ID copied'), findsOneWidget);
    expect(find.byKey(toastKey), findsOneWidget);

    // Tap dismisses the toast early (exit animation, then removal).
    await tester.tap(find.byKey(toastKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(find.byKey(toastKey), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('capsule toast respects the Chinese l10n copy strings', (
    tester,
  ) async {
    await pumpToastLauncher(
      tester,
      message: LicoStrings.forLocale(
        const Locale('zh'),
      ).conversationMessageCopied,
      locale: const Locale('zh'),
    );
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('消息已复制'), findsOneWidget);
    expect(find.byKey(toastKey), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 2000));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(find.byKey(toastKey), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pulse-enabled capsule drives the shared top-edge pulse', (
    tester,
  ) async {
    await pumpToastLauncher(tester, message: 'Copied', pulse: true);
    await tester.pump(const Duration(milliseconds: 250));

    final pulse = tester.widget<LicoTopEdgePulse>(find.byKey(pulseKey));
    expect(pulse.enabled, isTrue);
    expect(find.byKey(toastKey), findsOneWidget);

    await tester.tap(find.byKey(toastKey));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump();
    expect(find.byKey(toastKey), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
