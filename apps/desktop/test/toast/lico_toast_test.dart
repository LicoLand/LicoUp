import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/contracts/agent_conversation_tab_activity.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/lico_toast.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/chrome/chrome_projection.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

void main() {
  Future<void> pumpHostApp(
    WidgetTester tester, {
    Locale locale = const Locale('en'),
    ValueNotifier<LicoToastNoticesSnapshot>? notices,
    required Widget child,
  }) {
    return tester.pumpWidget(
      MaterialApp(
        locale: locale,
        supportedLocales: LicoStrings.supportedLocales,
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
        ],
        theme: buildLicoTheme(platformBrightness: Brightness.dark),
        home: LicoToastHost(
          child: LicoToastNoticesListener(
            notices: notices ?? ValueNotifier(const LicoToastNoticesSnapshot()),
            child: child,
          ),
        ),
      ),
    );
  }

  Future<void> showToast(
    WidgetTester tester,
    String message, {
    LicoToastKind kind = LicoToastKind.info,
    Duration showDuration = const Duration(seconds: 10),
  }) async {
    final element = tester.element(find.byKey(const Key('toast-context')));
    showLicoToast(
      element,
      message: message,
      kind: kind,
      showDuration: showDuration,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
  }

  Widget contextProbe() => Scaffold(
    body: Builder(
      builder: (context) => const SizedBox.shrink(key: Key('toast-context')),
    ),
  );

  group('toast kinds', () {
    testWidgets('each kind surfaces as a floating LicoToast, never a SnackBar', (
      tester,
    ) async {
      await pumpHostApp(tester, child: contextProbe());

      for (final kind in LicoToastKind.values) {
        await showToast(tester, 'kind-${kind.name}', kind: kind);
      }

      expect(find.byType(LicoToast), findsNWidgets(LicoToastKind.values.length));
      expect(find.byType(SnackBar), findsNothing);
      for (final kind in LicoToastKind.values) {
        expect(find.text('kind-${kind.name}'), findsOneWidget);
      }
      final kinds = tester
          .widgetList<LicoToast>(find.byType(LicoToast))
          .map((toast) => toast.kind)
          .toSet();
      expect(kinds, containsAll(LicoToastKind.values));
      expect(tester.takeException(), isNull);
    });
  });

  group('stacking', () {
    testWidgets('toasts stack bottom-anchored with the newest lowest', (
      tester,
    ) async {
      await pumpHostApp(tester, child: contextProbe());

      await showToast(tester, 'first');
      await showToast(tester, 'second');
      await showToast(tester, 'third');

      expect(find.byType(LicoToast), findsNWidgets(3));
      final first = tester.getRect(find.text('first'));
      final second = tester.getRect(find.text('second'));
      final third = tester.getRect(find.text('third'));
      expect(second.center.dy, greaterThan(first.center.dy));
      expect(third.center.dy, greaterThan(second.center.dy));
      final surfaceHeight =
          tester.view.physicalSize.height / tester.view.devicePixelRatio;
      final newest = tester.getRect(find.byType(LicoToast).last);
      expect(
        newest.bottom,
        closeTo(surfaceHeight - 16, 2),
        reason: 'the stack stays bottom-anchored with the shared 16px margin',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('re-showing the same message and kind replaces, not stacks', (
      tester,
    ) async {
      await pumpHostApp(tester, child: contextProbe());

      await showToast(tester, 'Copied', kind: LicoToastKind.success);
      await showToast(tester, 'Copied', kind: LicoToastKind.success);

      expect(find.byType(LicoToast), findsOneWidget);
      expect(find.text('Copied'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('the stack evicts the oldest beyond four visible toasts', (
      tester,
    ) async {
      await pumpHostApp(tester, child: contextProbe());

      for (var i = 0; i < 5; i++) {
        await showToast(tester, 'toast-$i');
      }

      expect(find.byType(LicoToast), findsNWidgets(4));
      expect(find.text('toast-0'), findsNothing);
      expect(find.text('toast-4'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('dismissal', () {
    testWidgets('a toast auto-dismisses after its duration', (tester) async {
      await pumpHostApp(tester, child: contextProbe());

      await showToast(
        tester,
        'ephemeral',
        showDuration: const Duration(milliseconds: 400),
      );
      expect(find.text('ephemeral'), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();
      expect(find.text('ephemeral'), findsNothing);
      expect(find.byType(LicoToast), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a tap dismisses a toast early', (tester) async {
      await pumpHostApp(tester, child: contextProbe());

      await showToast(tester, 'tap me');
      expect(find.text('tap me'), findsOneWidget);

      await tester.tap(find.text('tap me'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pump();
      expect(find.text('tap me'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('fallback without a host', () {
    testWidgets(
      'showLicoToast routes to the legacy appleGlassSnackBar exactly',
      (tester) async {
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
              body: Builder(
                builder: (context) => TextButton(
                  key: const Key('show-fallback'),
                  onPressed: () =>
                      showLicoToast(context, message: 'Legacy copied'),
                  child: const Text('Show'),
                ),
              ),
            ),
          ),
        );

        await tester.tap(find.byKey(const Key('show-fallback')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));

        expect(find.byKey(const Key('apple-glass-snackbar')), findsOneWidget);
        expect(find.byType(SnackBar), findsOneWidget);
        expect(find.text('Legacy copied'), findsOneWidget);
        expect(find.byType(LicoToast), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('notices listener', () {
    ChromeOperationNotificationProjection operationNotice({
      required String id,
      required String messageEnglish,
      String messageChinese = '中文消息',
      PresentationNoticeSeverity severity = PresentationNoticeSeverity.error,
    }) => ChromeOperationNotificationProjection(
      id: id,
      messageChinese: messageChinese,
      messageEnglish: messageEnglish,
      severity: severity,
      reasonCode: 'test_reason',
    );

    testWidgets('notices already present at mount stay silent', (tester) async {
      final notices = ValueNotifier(
        LicoToastNoticesSnapshot(
          operationNotices: [operationNotice(id: 'a', messageEnglish: 'old')],
          agentNotices: const [
            LicoToastAgentNotice(
              id: 'codex',
              displayName: 'Codex',
              activity: AgentConversationTabActivity.needsApproval,
            ),
          ],
          operationRevision: 3,
        ),
      );
      await pumpHostApp(tester, notices: notices, child: contextProbe());
      await tester.pump();

      expect(find.byType(LicoToast), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'an operation notice arrival toasts with severity-mapped kind',
      (tester) async {
        final notices = ValueNotifier(const LicoToastNoticesSnapshot());
        await pumpHostApp(tester, notices: notices, child: contextProbe());

        notices.value = LicoToastNoticesSnapshot(
          operationNotices: [
            operationNotice(
              id: 'a',
              messageEnglish: 'Gateway failed',
              severity: PresentationNoticeSeverity.error,
            ),
            operationNotice(
              id: 'b',
              messageEnglish: 'Pairing unstable',
              severity: PresentationNoticeSeverity.warning,
            ),
            operationNotice(
              id: 'c',
              messageEnglish: 'Sync complete',
              severity: PresentationNoticeSeverity.success,
            ),
          ],
          operationRevision: 1,
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));

        expect(find.byType(LicoToast), findsNWidgets(3));
        expect(find.byType(SnackBar), findsNothing);
        final byMessage = <String, LicoToast>{
          for (final toast in tester.widgetList<LicoToast>(
            find.byType(LicoToast),
          ))
            toast.message: toast,
        };
        expect(byMessage['Gateway failed']?.kind, LicoToastKind.error);
        expect(byMessage['Gateway failed']?.icon, isNull);
        final warning = byMessage['Pairing unstable'];
        expect(warning?.kind, LicoToastKind.error);
        expect(warning?.icon, Icons.warning_amber_rounded);
        expect(byMessage['Sync complete']?.kind, LicoToastKind.success);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('operation toasts render the Chinese message under zh locale', (
      tester,
    ) async {
      final notices = ValueNotifier(const LicoToastNoticesSnapshot());
      await pumpHostApp(
        tester,
        notices: notices,
        locale: const Locale('zh'),
        child: contextProbe(),
      );

      notices.value = LicoToastNoticesSnapshot(
        operationNotices: [
          operationNotice(
            id: 'a',
            messageEnglish: 'English text',
            messageChinese: '网关恢复失败',
          ),
        ],
        operationRevision: 1,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('网关恢复失败'), findsOneWidget);
      expect(find.text('English text'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      'a changed notice re-toasts while an identical republish does not',
      (tester) async {
        final notices = ValueNotifier(const LicoToastNoticesSnapshot());
        await pumpHostApp(tester, notices: notices, child: contextProbe());
        LicoToastNoticesSnapshot snapshot(String message, int revision) =>
            LicoToastNoticesSnapshot(
              operationNotices: [
                operationNotice(id: 'a', messageEnglish: message),
              ],
              operationRevision: revision,
            );

        notices.value = snapshot('first', 1);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        expect(find.text('first'), findsOneWidget);

        // Identical content republished with a higher revision: no duplicate.
        notices.value = snapshot('first', 2);
        await tester.pump();
        expect(find.text('first'), findsOneWidget);

        // Changed content under the same id surfaces again.
        notices.value = snapshot('second', 3);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 250));
        expect(find.text('second'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );

    testWidgets('gateway notices toast on a revision advance', (tester) async {
      final notices = ValueNotifier(const LicoToastNoticesSnapshot());
      await pumpHostApp(tester, notices: notices, child: contextProbe());

      notices.value = const LicoToastNoticesSnapshot(
        gatewayNotice: ChromeGatewayNotificationProjection(
          kind: ChromeGatewayNoticeKind.recovering,
          recoveryAttempt: 1,
          maxRecoveryAttempts: 3,
          busy: true,
        ),
        gatewayRevision: 1,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('Recovering LLM Gateway (1/3)…'), findsOneWidget);
      expect(
        tester.widget<LicoToast>(find.byType(LicoToast)).kind,
        LicoToastKind.info,
      );

      notices.value = const LicoToastNoticesSnapshot(
        gatewayNotice: ChromeGatewayNotificationProjection(
          kind: ChromeGatewayNoticeKind.recoveryFailed,
          recoveryAttempt: 3,
          maxRecoveryAttempts: 3,
          busy: false,
        ),
        gatewayRevision: 2,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(
        find.text('LLM Gateway recovery failed. Diagnostics recorded.'),
        findsOneWidget,
      );
      final failed = tester
          .widgetList<LicoToast>(find.byType(LicoToast))
          .firstWhere(
            (toast) => toast.message.startsWith('LLM Gateway recovery'),
          );
      expect(failed.kind, LicoToastKind.error);
      expect(failed.icon, Icons.warning_amber_rounded);
      expect(tester.takeException(), isNull);
    });

    testWidgets('agent activity notices toast as notification kind', (
      tester,
    ) async {
      final notices = ValueNotifier(const LicoToastNoticesSnapshot());
      await pumpHostApp(tester, notices: notices, child: contextProbe());

      notices.value = const LicoToastNoticesSnapshot(
        agentNotices: [
          LicoToastAgentNotice(
            id: 'codex',
            displayName: 'Codex',
            activity: AgentConversationTabActivity.needsApproval,
          ),
        ],
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('Codex · Needs approval'), findsOneWidget);
      expect(
        tester.widget<LicoToast>(find.byType(LicoToast)).kind,
        LicoToastKind.notification,
      );

      // An activity transition for the same target surfaces again.
      notices.value = const LicoToastNoticesSnapshot(
        agentNotices: [
          LicoToastAgentNotice(
            id: 'codex',
            displayName: 'Codex',
            activity: AgentConversationTabActivity.workFinished,
          ),
        ],
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.text('Codex · Work finished'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a restarted revision counter rebaselines without toasting', (
      tester,
    ) async {
      final notices = ValueNotifier(
        LicoToastNoticesSnapshot(
          operationNotices: [operationNotice(id: 'a', messageEnglish: 'one')],
          operationRevision: 5,
        ),
      );
      await pumpHostApp(tester, notices: notices, child: contextProbe());
      await tester.pump();
      expect(find.byType(LicoToast), findsNothing);

      // Fresh session: the counter restarts below the seen value.
      notices.value = LicoToastNoticesSnapshot(
        operationNotices: [operationNotice(id: 'b', messageEnglish: 'two')],
        operationRevision: 1,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));
      expect(find.byType(LicoToast), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });
}
