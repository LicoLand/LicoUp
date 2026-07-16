import 'package:flutter/material.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/history_session_panel.dart';
import 'package:flutter_client/src/frontend/shared/ui/lico_activity_animations.dart';
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
    expect(find.byIcon(Icons.chevron_right), findsNothing);
    expect(find.byIcon(Icons.expand_more), findsNothing);
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

  testWidgets('history session rows render as a flat list', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _historyPanelTestApp(
        HistorySessionPanel(
          title: '历史对话',
          subtitle: '1 条对话',
          items: const [
            HistorySessionPanelItem(
              id: 'session-1',
              title: '扁平行',
              active: true,
            ),
          ],
          onSelect: (String _) {},
        ),
      ),
    );

    final row = tester.widget<Material>(
      find.byKey(const Key('history-session-row-session-1')),
    );
    expect(row.borderRadius, isNull);
    expect(row.shape, isNull);
  });

  testWidgets('history delegate tracks stable session keys after reorder', (
    WidgetTester tester,
  ) async {
    const firstKey = ValueKey<String>('session-1');

    Future<void> pumpItems(List<HistorySessionPanelItem> items) {
      return tester.pumpWidget(
        _historyPanelTestApp(
          HistorySessionPanel(
            title: 'History',
            subtitle: '',
            items: items,
            onSelect: (String _) {},
          ),
        ),
      );
    }

    await pumpItems(const [
      HistorySessionPanelItem(id: 'session-1', title: 'First'),
      HistorySessionPanelItem(id: 'session-2', title: 'Second'),
    ]);

    expect(find.byKey(firstKey), findsOneWidget);
    var listView = tester.widget<ListView>(find.byType(ListView));
    var delegate = listView.childrenDelegate as SliverChildBuilderDelegate;
    expect(delegate.findChildIndexCallback?.call(firstKey), 0);

    await pumpItems(const [
      HistorySessionPanelItem(id: 'session-2', title: 'Second'),
      HistorySessionPanelItem(id: 'session-1', title: 'First'),
    ]);

    expect(find.byKey(firstKey), findsOneWidget);
    listView = tester.widget<ListView>(find.byType(ListView));
    delegate = listView.childrenDelegate as SliverChildBuilderDelegate;
    expect(delegate.findChildIndexCallback?.call(firstKey), 1);
  });

  testWidgets('history session panel title is not a collapse control', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _historyPanelTestApp(
        HistorySessionPanel(
          title: '历史对话',
          subtitle: '1 条对话',
          items: const [
            HistorySessionPanelItem(id: 'session-1', title: '默认展开会话'),
          ],
          onSelect: (String _) {},
        ),
      ),
    );

    expect(find.text('默认展开会话'), findsOneWidget);
    expect(find.byIcon(Icons.chevron_right), findsNothing);
    expect(find.byIcon(Icons.expand_more), findsNothing);

    await tester.tap(find.text('历史对话'));
    await tester.pump();

    expect(find.text('默认展开会话'), findsOneWidget);
  });

  testWidgets('history session panel can show left and right header actions', (
    WidgetTester tester,
  ) async {
    var archived = false;
    var created = false;

    await tester.pumpWidget(
      _historyPanelTestApp(
        HistorySessionPanel(
          title: '历史对话',
          subtitle: '1 条对话',
          items: const [
            HistorySessionPanelItem(id: 'session-1', title: '需要归档的会话'),
          ],
          onSelect: (String _) {},
          leading: IconButton(
            tooltip: '归档当前智能体对话',
            icon: const Icon(Icons.archive_outlined),
            onPressed: () => archived = true,
          ),
          trailing: IconButton(
            tooltip: '新增对话',
            icon: const Icon(Icons.add_comment_outlined),
            onPressed: () => created = true,
          ),
        ),
      ),
    );

    expect(find.text('需要归档的会话'), findsOneWidget);
    expect(
      tester.getTopLeft(find.byTooltip('归档当前智能体对话')).dx,
      lessThan(tester.getTopLeft(find.byTooltip('新增对话')).dx),
    );

    await tester.tap(find.byTooltip('归档当前智能体对话'));
    await tester.tap(find.byTooltip('新增对话'));

    expect(archived, isTrue);
    expect(created, isTrue);
  });

  testWidgets('history session panel collapse button hides the list', (
    WidgetTester tester,
  ) async {
    var collapsedState = false;

    await tester.pumpWidget(
      _historyPanelTestApp(
        HistorySessionPanel(
          title: '历史对话',
          subtitle: '',
          showHeaderText: false,
          collapsible: true,
          collapseTooltip: '收起历史对话',
          expandTooltip: '展开历史对话',
          onCollapsedChanged: (collapsed) => collapsedState = collapsed,
          items: const [
            HistorySessionPanelItem(id: 'session-1', title: '需要收起的会话'),
          ],
          onSelect: (String _) {},
          leading: IconButton(
            tooltip: '归档当前智能体对话',
            icon: const Icon(Icons.archive_outlined),
            onPressed: () {},
          ),
        ),
      ),
    );

    expect(find.text('历史对话'), findsNothing);
    expect(find.text('需要收起的会话'), findsOneWidget);
    expect(find.byTooltip('归档当前智能体对话'), findsOneWidget);
    expect(find.byTooltip('收起历史对话'), findsOneWidget);

    await tester.tap(find.byTooltip('收起历史对话'));
    await tester.pump();

    expect(collapsedState, isTrue);
    expect(find.text('需要收起的会话'), findsNothing);
    expect(find.byTooltip('归档当前智能体对话'), findsNothing);
    expect(find.byTooltip('展开历史对话'), findsOneWidget);
  });

  testWidgets('history session panel filters histories by token prefixes', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _historyPanelTestApp(
        HistorySessionPanel(
          title: '历史对话',
          subtitle: '3 条对话',
          searchable: true,
          searchHint: '搜索历史对话',
          noSearchResultsLabel: '没有匹配的历史对话',
          items: const [
            HistorySessionPanelItem(
              id: 'session-1',
              title: 'Stytio Brand Identity Design',
              meta: 'claude-code · brand-project',
              preview: 'Reviewed assets',
            ),
            HistorySessionPanelItem(
              id: 'session-2',
              title: 'Migration Matrix',
              meta: 'codex · architecture-graph',
              preview: 'Old path to new path status',
            ),
            HistorySessionPanelItem(
              id: 'session-3',
              title: 'Vultr CLI login',
              meta: 'codex · cloud-notes',
              preview: 'Use VULTR_API_KEY',
            ),
          ],
          onSelect: (String _) {},
        ),
      ),
    );

    expect(find.text('历史对话'), findsNothing);
    expect(find.text('搜索历史对话'), findsOneWidget);
    expect(find.text('Stytio Brand Identity Design'), findsOneWidget);
    expect(find.text('Migration Matrix'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'mi mat');
    await tester.pump();

    expect(find.text('Migration Matrix'), findsOneWidget);
    expect(find.text('Stytio Brand Identity Design'), findsNothing);
    expect(find.text('Vultr CLI login'), findsNothing);
    expect(find.text('1/3'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'cla pro');
    await tester.pump();

    expect(find.text('Stytio Brand Identity Design'), findsOneWidget);
    expect(find.text('Migration Matrix'), findsNothing);

    await tester.enterText(find.byType(TextField), 'missing');
    await tester.pump();

    expect(find.text('没有匹配的历史对话'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();

    expect(find.text('Stytio Brand Identity Design'), findsOneWidget);
    expect(find.text('Migration Matrix'), findsOneWidget);
    expect(find.text('Vultr CLI login'), findsOneWidget);
  });

  testWidgets('history session panel requests more histories near the end', (
    WidgetTester tester,
  ) async {
    var loadMoreCalls = 0;
    final items = List.generate(
      20,
      (index) => HistorySessionPanelItem(
        id: 'session-$index',
        title: '历史对话 $index',
        meta: 'codex',
      ),
    );

    await tester.pumpWidget(
      _historyPanelTestApp(
        SizedBox(
          width: 360,
          height: 190,
          child: HistorySessionPanel(
            title: '历史对话',
            subtitle: '20 条对话',
            items: items,
            maxListHeight: 120,
            hasMore: true,
            loadMoreLabel: '继续加载历史',
            onLoadMore: () => loadMoreCalls += 1,
            onSelect: (String _) {},
          ),
        ),
      ),
    );

    final listView = tester.widget<ListView>(find.byType(ListView));
    listView.controller?.jumpTo(listView.controller!.position.maxScrollExtent);
    await tester.pump();

    expect(loadMoreCalls, greaterThanOrEqualTo(1));
  });

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
                title: 'codex spark 和标准模型的使用场景有什么区别',
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
    expect(find.textContaining('codex spark'), findsOneWidget);
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

  test('historySessionProjectLabel uses the last path segment', () {
    expect(
      historySessionProjectLabel('/workspace/DevSpace/LicoLite'),
      'LicoLite',
    );
    expect(historySessionProjectLabel(r'C:\work\pactium\'), 'pactium');
    expect(historySessionProjectLabel('', fallback: '未关联项目'), '未关联项目');
  });

  test('historySessionGroupEntries keeps newest-first group order', () {
    final entries = historySessionGroupEntries(const [
      HistorySessionPanelItem(
        id: 'a1',
        title: 'CI release',
        groupKey: '/repo/licolite',
        groupLabel: 'licolite',
      ),
      HistorySessionPanelItem(
        id: 'b1',
        title: 'macOS client',
        groupKey: '/repo/lico-arc',
        groupLabel: 'lico-arc',
      ),
      HistorySessionPanelItem(
        id: 'a2',
        title: 'validation',
        groupKey: '/repo/licolite',
        groupLabel: 'licolite',
      ),
    ]);

    expect(
      entries
          .map((entry) => entry.isHeader ? entry.groupLabel : entry.item!.id)
          .toList(),
      ['licolite', 'a1', 'a2', 'lico-arc', 'b1'],
    );
  });

  testWidgets('history session panel can render project groups', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _historyPanelTestApp(
        HistorySessionPanel(
          title: '历史对话',
          subtitle: '',
          groupByProject: true,
          items: const [
            HistorySessionPanelItem(
              id: 'session-1',
              title: 'CI release workflow',
              meta: '7m',
              groupKey: '/repo/licolite',
              groupLabel: 'licolite',
              active: true,
            ),
            HistorySessionPanelItem(
              id: 'session-2',
              title: 'macOS client frontend',
              meta: '1d',
              groupKey: '/repo/lico-arc',
              groupLabel: 'lico-arc',
            ),
          ],
          onSelect: (String _) {},
        ),
      ),
    );

    expect(find.text('licolite'), findsOneWidget);
    expect(find.text('lico-arc'), findsOneWidget);
    expect(find.byIcon(Icons.folder_outlined), findsNWidgets(2));
    expect(find.text('CI release workflow'), findsOneWidget);
    expect(find.text('7m'), findsOneWidget);

    final row = tester.widget<Material>(
      find.byKey(const Key('history-session-row-session-1')),
    );
    expect(row.borderRadius, BorderRadius.circular(8));
    expect(find.byKey(const ValueKey<String>('session-1')), findsOneWidget);
  });

  testWidgets('running history row shows spinner instead of relative time', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _historyPanelTestApp(
        MediaQuery(
          data: const MediaQueryData(disableAnimations: true),
          child: HistorySessionPanel(
            title: '历史对话',
            subtitle: '',
            groupByProject: true,
            items: const [
              HistorySessionPanelItem(
                id: 'session-running',
                title: '优化对话刷新调度',
                meta: '1m',
                groupKey: '/repo/LicoArc',
                groupLabel: 'LicoArc',
                running: true,
                active: true,
              ),
            ],
            onSelect: (String _) {},
          ),
        ),
      ),
    );

    expect(find.text('优化对话刷新调度'), findsOneWidget);
    expect(find.text('1m'), findsNothing);
    expect(find.byType(LicoSpinningRefreshIcon), findsOneWidget);
    expect(find.byType(LicoShimmerText), findsOneWidget);
  });
}
