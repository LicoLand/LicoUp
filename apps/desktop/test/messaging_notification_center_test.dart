import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/application/features/messaging/messaging_notification_center.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/lico_toast.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/chrome/chrome_projection.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

/// The notification center no longer feeds a bell popover: its publishes
/// surface as unified floating toasts through the chrome notification-notices
/// exposure and [LicoToastNoticesListener]. These tests drive the real
/// [MessagingNotificationCenter] and mirror the chrome projection producer's
/// item-to-notice mapping to prove the surfacing end to end.
void main() {
  late MessagingNotificationCenter center;
  late ValueNotifier<LicoToastNoticesSnapshot> notices;

  void syncExposureFromCenter() {
    notices.value = LicoToastNoticesSnapshot(
      operationNotices: [
        for (final item in center.items)
          ChromeOperationNotificationProjection(
            id: item.id,
            messageChinese: item.messageChinese,
            messageEnglish: item.messageEnglish,
            severity: switch (item.tone) {
              MessagingNotificationTone.info =>
                PresentationNoticeSeverity.information,
              MessagingNotificationTone.warning =>
                PresentationNoticeSeverity.warning,
              MessagingNotificationTone.failure =>
                PresentationNoticeSeverity.error,
              MessagingNotificationTone.success =>
                PresentationNoticeSeverity.success,
            },
            reasonCode: item.code,
          ),
      ],
      operationRevision: center.revision,
    );
  }

  Future<void> pumpSurface(WidgetTester tester, {Locale? locale}) {
    return tester.pumpWidget(
      MaterialApp(
        locale: locale ?? const Locale('en'),
        supportedLocales: LicoStrings.supportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        theme: buildLicoTheme(platformBrightness: Brightness.dark),
        home: LicoToastHost(
          child: LicoToastNoticesListener(
            notices: notices,
            child: const Scaffold(body: SizedBox.shrink()),
          ),
        ),
      ),
    );
  }

  setUp(() {
    center = MessagingNotificationCenter();
    notices = ValueNotifier(const LicoToastNoticesSnapshot());
  });

  tearDown(() {
    center.dispose();
    notices.dispose();
  });

  testWidgets('a published center notice surfaces as a floating toast', (
    tester,
  ) async {
    await pumpSurface(tester);

    center.publish(
      id: 'subagent-mcp-cursor',
      messageChinese: '第一次',
      messageEnglish: 'first',
      tone: MessagingNotificationTone.warning,
      code: 'subagent_mcp_unsupported',
    );
    syncExposureFromCenter();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('first'), findsOneWidget);
    expect(find.byType(LicoToast), findsOneWidget);
    expect(find.byType(SnackBar), findsNothing);
    // The bell popover is gone: no notification-center panel chrome remains.
    expect(
      find.byKey(const Key('messaging-notification-bell-panel')),
      findsNothing,
    );
    expect(find.byKey(const Key('messaging-notification-bell')), findsNothing);
    // The warning tone keeps the legacy amber glyph on the unified toast.
    final toast = tester.widget<LicoToast>(find.byType(LicoToast));
    expect(toast.kind, LicoToastKind.error);
    expect(toast.icon, Icons.warning_amber_rounded);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a replacement publish surfaces the new content as a toast', (
    tester,
  ) async {
    await pumpSurface(tester);

    center.publish(
      id: 'subagent-mcp-cursor',
      messageChinese: '第一次',
      messageEnglish: 'first',
      tone: MessagingNotificationTone.warning,
      code: 'subagent_mcp_unsupported',
    );
    syncExposureFromCenter();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(find.text('first'), findsOneWidget);

    center.publish(
      id: 'subagent-mcp-cursor',
      messageChinese: '第二次',
      messageEnglish: 'second',
      tone: MessagingNotificationTone.failure,
      code: 'subagent_mcp_unsupported',
    );
    syncExposureFromCenter();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('second'), findsOneWidget);
    final surfaced = tester
        .widgetList<LicoToast>(find.byType(LicoToast))
        .firstWhere((toast) => toast.message == 'second');
    expect(surfaced.kind, LicoToastKind.error);
    expect(surfaced.icon, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('published notices render their Chinese message under zh', (
    tester,
  ) async {
    await pumpSurface(tester, locale: const Locale('zh'));

    center.publish(
      id: 'subagent-mcp-cursor',
      messageChinese: '子代理通道不受支持',
      messageEnglish: 'unsupported',
      tone: MessagingNotificationTone.failure,
      code: 'subagent_mcp_unsupported',
    );
    syncExposureFromCenter();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.text('子代理通道不受支持'), findsOneWidget);
    expect(find.text('unsupported'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
