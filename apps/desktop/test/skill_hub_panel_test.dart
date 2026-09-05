import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:licoup/src/frontend/features/skill_hub/ui/skill_hub_panel.dart';
import 'package:licoup/src/frontend/features/skill_hub/ui/skill_hub_panel_card_support.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/agent_brand_icon.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';
import 'package:licoup/src/presentation/skill_hub/skill_hub_projection.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/skill_hub_binding_fixture.dart';

void main() {
  testWidgets('Skill Hub shows centered scanning state while busy and empty', (
    tester,
  ) async {
    final fixture = SkillHubBindingFixture(
      skills: const [],
      phase: PresentationPhase.loading,
    );
    addTearDown(fixture.dispose);

    await _pumpSkillHub(tester, fixture: fixture, locale: const Locale('zh'));

    expect(find.text('扫描中...'), findsOneWidget);
    expect(find.text('未发现技能'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsWidgets);
  });

  testWidgets(
    'English Skill Hub filters cards and infers non-empty loader icons',
    (tester) async {
      final fixture = _skillHubFixture();
      addTearDown(fixture.dispose);

      await _pumpSkillHub(tester, fixture: fixture, locale: const Locale('en'));

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
      final fixture = _skillHubFixture();
      addTearDown(fixture.dispose);

      await _pumpSkillHub(tester, fixture: fixture, locale: const Locale('zh'));

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
      final fixture = _skillHubFixture();
      addTearDown(fixture.dispose);

      await _pumpSkillHub(tester, fixture: fixture, locale: const Locale('en'));

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

      expect(fixture.plannedSkillId, 'public-reviewer');
      expect(
        fixture.plannedPath,
        '<portable-root>/.agents/skills/public-reviewer',
      );
      expect(fixture.appliedConfirmation, 'trash:public-reviewer:test-plan');
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
      final fixture = _skillHubFixture();
      addTearDown(fixture.dispose);

      await _pumpSkillHub(tester, fixture: fixture, locale: const Locale('zh'));

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
      final fixture = _skillHubFixture();
      addTearDown(fixture.dispose);

      await _pumpSkillHub(tester, fixture: fixture, locale: const Locale('en'));

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
      final fixture = SkillHubBindingFixture(
        skills: [
          skillHubFixtureSkill(
            id: 'sample-wrap-skill',
            name: 'flutter-implement-json-serialization',
            author: 'Sample Author',
            description: longDescription,
            version: '1.0.0',
            isPublic: false,
            path: '/skills/sample-wrap-skill',
          ),
        ],
      );
      addTearDown(fixture.dispose);

      await _pumpSkillHub(tester, fixture: fixture, locale: const Locale('en'));

      final title = tester.widget<Text>(
        find.descendant(
          of: find.byType(SkillCardTitle),
          matching: find.byType(Text),
        ),
      );
      expect(title.maxLines, 2);
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
      expect(paragraph.size.height, closeTo(49, 0.5));
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
    final fixture = SkillHubBindingFixture(
      skills: [
        skillHubFixtureSkill(
          id: 'sample-short-skill',
          name: 'Short Skill',
          author: 'Sample Author',
          description: shortDescription,
          isPublic: false,
          path: '/skills/sample-short-skill',
        ),
      ],
    );
    addTearDown(fixture.dispose);

    await _pumpSkillHub(tester, fixture: fixture, locale: const Locale('en'));

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
  required SkillHubBindingFixture fixture,
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
          child: SkillHubPanel(binding: fixture.binding),
        ),
      ),
    ),
  );
  await tester.pump();
}

SkillHubBindingFixture _skillHubFixture() {
  return SkillHubBindingFixture(
    phase: PresentationPhase.loading,
    skills: [
      skillHubFixtureSkill(
        id: 'public-reviewer',
        name: 'Public Reviewer',
        author: 'Example Org',
        description: 'Reviews changes.',
        version: '1.2.3',
        isPublic: true,
        path: '<portable-root>/.agents/skills/public-reviewer',
        iconId: 'shield',
        agents: const [
          SkillAgentProjection(id: 'codex', label: 'Codex'),
          SkillAgentProjection(id: 'cursor', label: 'Cursor'),
          SkillAgentProjection(id: 'claude-code', label: 'Claude Code'),
          SkillAgentProjection(id: 'opencode', label: 'OpenCode'),
        ],
      ),
      skillHubFixtureSkill(
        id: 'private-helper',
        name: 'Private Helper',
        isPublic: false,
        path: '<portable-root>/.claude/skills/private-helper',
        iconId: 'wrench',
        agents: const [
          SkillAgentProjection(id: 'claude-code', label: 'Claude Code'),
        ],
      ),
    ],
  );
}

bool _hasTooltip(WidgetTester tester, String message) {
  return tester
      .widgetList<Tooltip>(find.byType(Tooltip))
      .any((tooltip) => tooltip.message == message);
}
