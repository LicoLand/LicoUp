import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_client/src/application/controller/client_controller.dart';
import 'package:flutter_client/src/contracts/target_candidate.dart';
import 'package:flutter_client/src/frontend/features/skill_hub/ui/skill_hub_panel.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/shared/ui/agent_brand_icon.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('Skill Hub shows centered scanning state while busy and empty', (
    tester,
  ) async {
    final controller = ClientController()
      ..isSkillHubBusy = true
      ..skillHubSkills = const [];
    addTearDown(controller.dispose);

    await _pumpSkillHub(
      tester,
      controller: controller,
      locale: const Locale('zh'),
    );

    expect(find.text('扫描中...'), findsOneWidget);
    expect(find.text('未发现技能'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsWidgets);
  });

  testWidgets(
    'English Skill Hub filters cards and infers non-empty loader icons',
    (tester) async {
      final controller = _skillHubController();
      addTearDown(controller.dispose);

      await _pumpSkillHub(
        tester,
        controller: controller,
        locale: const Locale('en'),
      );

      expect(
        find.text('Browse, pair, and install skills loadable by local agents.'),
        findsNothing,
      );
      expect(find.text('All Skills'), findsOneWidget);
      expect(find.text('Public Skills'), findsOneWidget);
      expect(find.text('Private Skills'), findsOneWidget);
      expect(find.text('Loadable by:'), findsNothing);
      expect(find.byType(SkillCategoryIconBadge), findsNWidgets(2));
      expect(find.byType(AgentBrandIcon), findsWidgets);
      expect(_hasTooltip(tester, 'Codex'), isTrue);
      expect(_hasTooltip(tester, 'Claude Code'), isTrue);

      await tester.tap(find.byType(SkillCategoryIconBadge).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Customize Skill Icon'), findsOneWidget);
      expect(find.text('Icon Color'), findsOneWidget);
      expect(find.text('Icon Glyph'), findsOneWidget);

      await tester.tap(find.text('Cancel'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.text('Public Skills'));
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('Public Reviewer'), findsOneWidget);
      expect(find.text('Example Org'), findsOneWidget);
      expect(find.text('Private Helper'), findsNothing);

      await tester.tap(find.text('Public Reviewer'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('Author: Example Org'), findsOneWidget);
      expect(find.text('Version: 1.2.3'), findsOneWidget);
      expect(
        find.text('Path: <portable-root>/.agents/skills/public-reviewer'),
        findsOneWidget,
      );
      expect(find.text('Type: Public'), findsOneWidget);

      await tester.tap(find.text('Close'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Chinese Skill Hub localizes chrome without translating skill content',
    (tester) async {
      final controller = _skillHubController();
      addTearDown(controller.dispose);

      await _pumpSkillHub(
        tester,
        controller: controller,
        locale: const Locale('zh'),
      );

      expect(find.text('技能中心'), findsNothing);
      expect(find.text('查看、配对并安装本机智能体可加载的技能。'), findsNothing);
      expect(find.text('全部技能'), findsOneWidget);
      expect(find.text('公共技能'), findsOneWidget);
      expect(find.text('私有技能'), findsOneWidget);
      expect(find.text('可加载：'), findsNothing);
      expect(find.byType(AgentBrandIcon), findsWidgets);
      expect(find.text('Public Reviewer'), findsOneWidget);
      expect(find.text('Example Org'), findsOneWidget);
      expect(find.text('Reviews changes.'), findsOneWidget);
      expect(find.text('Private Helper'), findsOneWidget);
      expect(find.text('暂无描述'), findsOneWidget);
      expect(find.text('Public Skills'), findsNothing);
      expect(_hasTooltip(tester, 'Claude Code'), isTrue);

      await tester.tap(find.text('Public Reviewer'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('作者: Example Org'), findsOneWidget);
      expect(find.textContaining('(Author)'), findsNothing);

      await tester.tap(find.text('关闭'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.text('Private Helper'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.text('类型: 私有'), findsOneWidget);
      expect(find.textContaining('作者:'), findsNothing);
      expect(find.text('描述: '), findsOneWidget);
      expect(find.textContaining('(Description)'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('settings gear opens a floating drawer with a minimal installer', (
    tester,
  ) async {
    final controller = _skillHubController()
      ..skillHubPairings = const [
        {'agentId': 'codex', 'target': 'manual', 'status': 'approved'},
      ];
    addTearDown(controller.dispose);

    await _pumpSkillHub(
      tester,
      controller: controller,
      locale: const Locale('zh'),
    );

    // Drawer closed: no settings content, filter chips stay in the top row.
    expect(find.text('GitHub URL'), findsNothing);
    expect(find.text('全部技能'), findsOneWidget);

    await tester.tap(find.byTooltip('显示技能设置'));
    await tester.pump();

    expect(find.text('设置'), findsOneWidget);
    expect(find.text('GitHub URL'), findsOneWidget);
    expect(find.text('安装'), findsOneWidget);
    // Pairing bookkeeping and retired settings rows stay out of the UI.
    expect(find.text('配对记录'), findsNothing);
    expect(find.text('多智能体删除'), findsNothing);
    expect(find.text('手动更新与自动更新'), findsNothing);
    expect(find.text('本机调用频率'), findsNothing);
    // The page behind is untouched and still listed.
    expect(find.text('Public Reviewer'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pump();

    expect(find.text('GitHub URL'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpSkillHub(
  WidgetTester tester, {
  required ClientController controller,
  required Locale locale,
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
        body: SizedBox(
          width: 900,
          height: 650,
          child: SkillHubPanel(controller: controller),
        ),
      ),
    ),
  );
  await tester.pump();
}

ClientController _skillHubController() {
  return ClientController()
    ..isSkillHubBusy = true
    ..scannedTargets = [
      _target('codex', 'ChatGPT - Desktop'),
      _target('cursor', 'Cursor - IDE'),
      _target('claude-code', 'Claude Code - CLI'),
      _target('opencode', 'OpenCode - CLI'),
    ]
    ..skillHubSkills = const [
      {
        'skillId': 'public-reviewer',
        'title': 'Public Reviewer',
        'author': 'Example Org',
        'description': 'Reviews changes.',
        'version': '1.2.3',
        'isPublic': true,
        'path': '<portable-root>/.agents/skills/public-reviewer',
        'usedByAgents': <String>[],
      },
      {
        'skillId': 'private-helper',
        'title': 'Private Helper',
        'description': '',
        'version': 'local',
        'isPublic': false,
        'path': '<portable-root>/.claude/skills/private-helper',
        'usedByAgents': <String>[],
      },
    ];
}

TargetCandidate _target(String id, String label) {
  return TargetCandidate(
    target: id,
    label: label,
    kind: 'cli',
    status: 'detected',
    configured: true,
    confidence: 1,
    adapterStatus: 'implemented',
  );
}

bool _hasTooltip(WidgetTester tester, String message) {
  return tester
      .widgetList<Tooltip>(find.byType(Tooltip))
      .any((tooltip) => tooltip.message == message);
}
