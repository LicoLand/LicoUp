import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/contracts/skill_delete.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/skill_hub/ui/skill_hub_panel.dart';
import 'package:licoup/src/frontend/features/skill_hub/ui/skill_hub_panel_card_support.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/agent_brand_icon.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
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
      expect(find.text('Skill Hub'), findsOneWidget);
      expect(find.text('Search skills'), findsNothing);
      expect(find.byKey(const Key('skill-hub-search')), findsNothing);
      expect(find.byKey(const Key('skill-hub-refresh')), findsOneWidget);
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

      expect(find.text('技能中心'), findsOneWidget);
      expect(find.text('搜索技能'), findsNothing);
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

  testWidgets(
    'skill details move the selected catalog directory to system trash',
    (tester) async {
      final gateway = _SkillTrashGateway();
      final controller = _skillHubController(skillDeleteGateway: gateway);
      addTearDown(controller.dispose);

      await _pumpSkillHub(
        tester,
        controller: controller,
        locale: const Locale('en'),
      );

      await tester.tap(find.text('Public Reviewer'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('skill-delete-button')), findsOneWidget);
      expect(find.text('Delete'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('skill-delete-button')));
      await tester.pumpAndSettle();

      expect(find.text('Delete this skill?'), findsOneWidget);
      expect(
        find.text(
          '"Public Reviewer" will move to the system trash, where it can be restored.',
        ),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const ValueKey('skill-move-to-trash-confirm')),
      );
      await tester.pumpAndSettle();

      expect(gateway.plannedSkillId, 'public-reviewer');
      expect(
        gateway.plannedPath,
        '<portable-root>/.agents/skills/public-reviewer',
      );
      expect(gateway.appliedConfirmation, 'trash:public-reviewer:test-plan');
      expect(find.text('Public Reviewer'), findsNothing);
      expect(
        find.text('Moved "Public Reviewer" to the system trash.'),
        findsOneWidget,
      );
    },
  );

  testWidgets(
    'skill hub omits the retired installer while preserving the local catalog',
    (tester) async {
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

      // Installation is no longer part of the local Skill Hub. The catalog
      // and its filters remain available without a settings drawer.
      expect(find.text('GitHub URL'), findsNothing);
      expect(find.text('全部技能'), findsOneWidget);
      expect(find.byTooltip('显示技能设置'), findsNothing);
      expect(find.text('安装'), findsNothing);
      // Pairing bookkeeping and retired settings rows stay out of the UI.
      expect(find.text('配对记录'), findsNothing);
      expect(find.text('多智能体删除'), findsNothing);
      expect(find.text('手动更新与自动更新'), findsNothing);
      expect(find.text('本机调用频率'), findsNothing);
      // The existing local catalog stays visible.
      expect(find.text('Public Reviewer'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Skill Hub main pane keeps category chips and has no search field',
    (tester) async {
      final controller = _skillHubController();
      addTearDown(controller.dispose);

      await _pumpSkillHub(
        tester,
        controller: controller,
        locale: const Locale('en'),
      );

      expect(find.byKey(const Key('skill-hub-search')), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(find.text('All Skills'), findsOneWidget);
      expect(find.text('Public Skills'), findsOneWidget);
      expect(find.text('Private Skills'), findsOneWidget);
      expect(find.text('Public Reviewer'), findsOneWidget);
      expect(find.text('Private Helper'), findsOneWidget);
    },
  );

  testWidgets(
    'skill card description ellipsizes at the end of three full lines',
    (tester) async {
      const longDescription =
          'alpha bravo charlie delta echo foxtrot golf hotel '
          'india juliet kilo lima mike november oscar papa quebec '
          'romeo sierra tango uniform victor whiskey xray yankee zulu '
          'wrapped line three continues with extra sample words so the '
          'card body must ellipsize after exactly three lines of text';
      final controller = _skillHubController()
        ..skillHubSkills = const [
          {
            'skillId': 'sample-wrap-skill',
            'title': 'flutter-implement-json-serialization',
            'author': 'Sample Author',
            'description': longDescription,
            'version': '1.0.0',
            'isPublic': false,
            'path': '/skills/sample-wrap-skill',
            'usedByAgents': <String>[],
          },
        ];
      addTearDown(controller.dispose);

      await _pumpSkillHub(
        tester,
        controller: controller,
        locale: const Locale('en'),
      );

      final title = tester.widget<Text>(
        find.descendant(
          of: find.byType(SkillCardTitle),
          matching: find.byType(Text),
        ),
      );
      expect(title.maxLines, SkillCardTitle.maxLines);
      expect(title.overflow, TextOverflow.ellipsis);
      expect(title.softWrap, isTrue);

      final description = tester.widget<Text>(
        find.descendant(
          of: find.byType(SkillCardDescription),
          matching: find.byType(Text),
        ),
      );
      expect(description.maxLines, 3);
      expect(description.overflow, TextOverflow.ellipsis);
      expect(description.softWrap, isTrue);

      final paragraph = _descriptionParagraph(tester);
      expect(paragraph.didExceedMaxLines, isTrue);
      final boxes = paragraph.getBoxesForSelection(
        TextSelection(baseOffset: 0, extentOffset: longDescription.length),
      );
      expect(_lineCount(boxes), 3);
      expect(
        paragraph.size.height,
        closeTo(SkillCardDescription.reservedHeight, 0.5),
      );
      for (final box in boxes) {
        expect(box.bottom, lessThanOrEqualTo(paragraph.size.height + 0.5));
      }
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('skill card short description is not clipped mid-glyph', (
    tester,
  ) async {
    const shortDescription = 'Short.';
    final controller = _skillHubController()
      ..skillHubSkills = const [
        {
          'skillId': 'sample-short-skill',
          'title': 'Short Skill',
          'author': 'Sample Author',
          'description': shortDescription,
          'version': 'local',
          'isPublic': false,
          'path': '/skills/sample-short-skill',
          'usedByAgents': <String>[],
        },
      ];
    addTearDown(controller.dispose);

    await _pumpSkillHub(
      tester,
      controller: controller,
      locale: const Locale('en'),
    );

    final paragraph = _descriptionParagraph(tester);
    expect(paragraph.didExceedMaxLines, isFalse);
    final boxes = paragraph.getBoxesForSelection(
      const TextSelection(baseOffset: 0, extentOffset: shortDescription.length),
    );
    expect(boxes, isNotEmpty);
    final origin = paragraph.localToGlobal(Offset.zero);
    final cardRect = tester.getRect(find.byType(Card));
    for (final box in boxes) {
      expect(box.bottom - box.top, greaterThanOrEqualTo(12));
      expect(box.bottom, lessThanOrEqualTo(paragraph.size.height + 0.5));
      final rect = Rect.fromLTRB(
        origin.dx + box.left,
        origin.dy + box.top,
        origin.dx + box.right,
        origin.dy + box.bottom,
      );
      expect(cardRect.inflate(0.5).contains(rect.topLeft), isTrue);
      expect(cardRect.inflate(0.5).contains(rect.bottomRight), isTrue);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'skill card title wraps a long name instead of mid-token ellipsis',
    (tester) async {
      const titleText = 'flutter-implement-json-serialization';
      await tester.pumpWidget(
        MaterialApp(
          theme: buildLicoTheme(platformBrightness: Brightness.dark),
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 160,
                child: SkillCardTitle(title: titleText, color: Colors.white),
              ),
            ),
          ),
        ),
      );
      await tester.pump();

      final title = tester.widget<Text>(find.text(titleText));
      expect(title.maxLines, 2);
      expect(title.overflow, TextOverflow.ellipsis);
      expect(title.softWrap, isTrue);

      final paragraph = tester.renderObject<RenderParagraph>(
        find.descendant(
          of: find.byType(SkillCardTitle),
          matching: find.byType(RichText),
        ),
      );
      final boxes = paragraph.getBoxesForSelection(
        const TextSelection(baseOffset: 0, extentOffset: titleText.length),
      );
      expect(_lineCount(boxes), greaterThan(1));
      expect(_lineCount(boxes), lessThanOrEqualTo(2));
      expect(boxes.first.right - boxes.first.left, greaterThan(120));
      expect(tester.takeException(), isNull);
    },
  );
}

RenderParagraph _descriptionParagraph(WidgetTester tester) {
  return tester.renderObject<RenderParagraph>(
    find.descendant(
      of: find.byType(SkillCardDescription),
      matching: find.byType(RichText),
    ),
  );
}

int _lineCount(List<TextBox> boxes) {
  return boxes.map((box) => box.top.round()).toSet().length;
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
      builder: (context, child) {
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(disableAnimations: true),
          child: child!,
        );
      },
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

ClientController _skillHubController({SkillDeleteGateway? skillDeleteGateway}) {
  return ClientController(skillDeleteGateway: skillDeleteGateway)
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

class _SkillTrashGateway implements SkillDeleteGateway {
  String plannedSkillId = '';
  String plannedPath = '';
  String appliedConfirmation = '';

  @override
  Future<Map<String, dynamic>> planSkillDelete({
    required String skillId,
    required String path,
  }) async {
    plannedSkillId = skillId;
    plannedPath = path;
    return {
      'ok': true,
      'status': 'trash_planned',
      'trashAllowed': true,
      'confirmation': 'trash:$skillId:test-plan',
    };
  }

  @override
  Future<Map<String, dynamic>> applySkillDelete({
    required String skillId,
    required String path,
    required String confirmation,
  }) async {
    appliedConfirmation = confirmation;
    return {'ok': true, 'status': 'trashed', 'trashedCount': 1};
  }
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
