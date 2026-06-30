import 'package:flutter/material.dart';
import 'package:flutter_client/src/ui/history_session_panel.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _historyPanelTestApp(Widget body) {
  return MaterialApp(
    theme: ThemeData(splashFactory: NoSplash.splashFactory),
    home: Scaffold(body: body),
  );
}

void main() {
  testWidgets('history session panel uses native agent history empty copy', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _historyPanelTestApp(
        HistorySessionPanel(
          title: '原生智能体历史',
          subtitle: '0 条原生智能体历史',
          items: const [],
          onSelect: (String _) {},
          onDelete: (String _) {},
        ),
      ),
    );

    expect(find.text('原生智能体历史'), findsOneWidget);
    expect(find.text('0 条原生智能体历史'), findsOneWidget);
    expect(find.text('No local sessions yet'), findsNothing);
    expect(find.text('No native agent histories yet'), findsOneWidget);
  });

  testWidgets(
    'history session panel row uses native agent history delete label',
    (WidgetTester tester) async {
      var selectedSession = '';
      var deletedSession = '';

      await tester.pumpWidget(
        _historyPanelTestApp(
          HistorySessionPanel(
            title: '原生智能体历史',
            subtitle: '1 条原生智能体历史',
            items: const [
              HistorySessionPanelItem(
                id: 'session-1',
                title: '汇总会话',
                preview: '最近一条消息',
                deleteLabel: 'Delete native agent history',
              ),
            ],
            onSelect: (String sessionId) => selectedSession = sessionId,
            onDelete: (String sessionId) => deletedSession = sessionId,
          ),
        ),
      );

      await tester.tap(find.text('汇总会话'));
      expect(selectedSession, 'session-1');

      await tester.tap(find.byIcon(Icons.delete_outline));
      expect(deletedSession, 'session-1');
    },
  );

  testWidgets('history session panel row fits title meta and preview', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _historyPanelTestApp(
        SizedBox(
          width: 480,
          height: 220,
          child: HistorySessionPanel(
            title: '原生智能体历史',
            subtitle: '1 条原生智能体历史',
            items: const [
              HistorySessionPanelItem(
                id: 'session-1',
                title: 'weekly limit 和 codex spark 的 weekly limit 是分开计费吗',
                meta:
                    'codex · codex-prompt-history · 019d952a-5e16-78e0-a627-b887',
                preview: '这里是一段很长的历史预览，应当在行内截断而不是撑出底部 overflow。',
                deleteLabel: 'Delete native agent history',
              ),
            ],
            onSelect: (String _) {},
            onDelete: (String _) {},
          ),
        ),
      ),
    );

    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.textContaining('weekly limit'), findsOneWidget);
  });

  testWidgets('history session panel can disable native history delete', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _historyPanelTestApp(
        HistorySessionPanel(
          title: '原生智能体历史',
          subtitle: '1 条原生智能体历史',
          items: const [
            HistorySessionPanelItem(
              id: 'session-1',
              title: '汇总会话',
              canDelete: false,
              deleteLabel: 'Read-only native agent history',
            ),
          ],
          onSelect: (String _) {},
          onDelete: (String _) {},
        ),
      ),
    );

    final button = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.delete_outline),
    );
    expect(button.onPressed, isNull);
  });
}
