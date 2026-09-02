import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/contracts/target_management.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_search_palette.dart';
import 'package:licoup/src/frontend/features/agents/ui/global_search_features.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/platform/native_client/agent_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'fixtures/client_controller/support/no_entry_hook_client_controller.dart';

void main() {
  testWidgets('palette ranks hits and groups them under their agent', (
    tester,
  ) async {
    final controller = ClientController()
      ..scannedTargets = [
        _target('codex', 'ChatGPT Codex - CLI'),
        _target('kimi-code', 'Kimi Code - CLI'),
      ]
      ..selectedConversationAgentId = ''
      ..selectedConversationSessionId = ''
      ..conversationSessionsByAgent = {
        'codex': [
          _session(
            'c1',
            'codex',
            'Fix the release pipeline',
            'pipeline keeps failing on the notarization step',
          ),
        ],
        'kimi-code': [
          _session(
            'k1',
            'kimi-code',
            'Random notes',
            'the release checklist lives here',
          ),
        ],
      };
    addTearDown(controller.dispose);

    await _pumpPalette(tester, controller);
    expect(find.text('搜索功能和所有对话的标题、内容'), findsWidgets);

    await tester.enterText(
      find.byKey(const Key('conversation-search-palette-input')),
      'release',
    );
    await tester.pump();

    // Both agents matched; the title hit leads and groups render as a tree.
    expect(find.text('Codex'), findsOneWidget);
    expect(find.text('Kimi Code'), findsOneWidget);
    expect(find.text('Fix the release pipeline'), findsOneWidget);
    expect(find.text('Random notes'), findsOneWidget);
    expect(find.textContaining('release checklist'), findsOneWidget);

    final codexHeader = tester.getTopLeft(find.text('Codex'));
    final kimiHeader = tester.getTopLeft(find.text('Kimi Code'));
    expect(codexHeader.dy, lessThan(kimiHeader.dy));
    expect(tester.takeException(), isNull);
  });

  testWidgets('palette enter activates the top hit', (tester) async {
    final agentService = _SearchPaletteAgentService();
    addTearDown(agentService.dispose);
    final controller = ClientController(agentService: agentService)
      ..scannedTargets = [_target('codex', 'ChatGPT Codex - CLI')]
      ..selectedConversationAgentId = ''
      ..selectedConversationSessionId = ''
      ..conversationSessionsByAgent = {
        'codex': [
          _session('c1', 'codex', 'Alpha topic', 'first body'),
          _session('c2', 'codex', 'Beta topic', 'alpha mention'),
        ],
      };
    addTearDown(controller.dispose);

    var closed = false;
    await _pumpPalette(tester, controller, onClose: () => closed = true);

    await tester.enterText(
      find.byKey(const Key('conversation-search-palette-input')),
      'alpha',
    );
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(closed, isTrue);
    expect(controller.selectedConversationAgentId, 'codex');
    expect(controller.selectedConversationSessionId, 'c1');
    expect(tester.takeException(), isNull);
  });

  testWidgets('palette surfaces skill matches and jumps to the skill hub', (
    tester,
  ) async {
    final controller = NoEntryHookClientController()
      ..scannedTargets = [_target('codex', 'ChatGPT Codex - CLI')]
      ..selectedConversationAgentId = ''
      ..selectedConversationSessionId = ''
      ..skillHubSkills = const [
        {
          'skillId': 'stitch-design-taste',
          'title': 'stitch-design-taste',
          'description': 'Semantic Design System Skill for Google Stitch.',
          'isPublic': true,
        },
        {
          'skillId': 'minimalist-ui',
          'title': 'minimalist-ui',
          'description': 'Clean editorial-style interfaces.',
          'isPublic': true,
        },
      ]
      ..conversationSessionsByAgent = const {};
    addTearDown(controller.dispose);

    var closed = false;
    await _pumpPalette(tester, controller, onClose: () => closed = true);

    await tester.enterText(
      find.byKey(const Key('conversation-search-palette-input')),
      'stitch',
    );
    await tester.pump();

    expect(find.text('技能中心'), findsOneWidget);
    expect(find.text('stitch-design-taste'), findsOneWidget);
    expect(find.text('minimalist-ui'), findsNothing);
    expect(
      find.text('Semantic Design System Skill for Google Stitch.'),
      findsOneWidget,
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(closed, isTrue);
    expect(controller.currentSection, ClientSection.skillHub);
    expect(tester.takeException(), isNull);
  });

  testWidgets('palette ranks feature jumps ahead of conversation hits', (
    tester,
  ) async {
    final controller = ClientController()
      ..scannedTargets = [_target('codex', 'ChatGPT Codex - CLI')]
      ..selectedConversationAgentId = ''
      ..selectedConversationSessionId = ''
      ..conversationSessionsByAgent = {
        'codex': [_session('c1', 'codex', 'Skill cleanup', 'skill notes')],
      };
    addTearDown(controller.dispose);

    ClientSection? jumpedTo;
    final features = buildGlobalSearchFeatures(
      strings: LicoStrings.forLocale(const Locale('zh')),
      onSelectSection: (section) => jumpedTo = section,
      onNewConversation: () {},
    );
    var closed = false;
    await _pumpPalette(
      tester,
      controller,
      features: features,
      onClose: () => closed = true,
    );

    await tester.enterText(
      find.byKey(const Key('conversation-search-palette-input')),
      'skill',
    );
    await tester.pump();

    // The feature group leads; conversation hits follow.
    expect(find.text('功能'), findsOneWidget);
    expect(find.text('技能中心'), findsOneWidget);
    expect(find.text('Skill cleanup'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('功能')).dy,
      lessThan(tester.getTopLeft(find.text('Skill cleanup')).dy),
    );

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(closed, isTrue);
    expect(jumpedTo, ClientSection.skillHub);
    expect(controller.selectedConversationSessionId, isNot('c1'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('settings destination shows no filler when nothing matches', (
    tester,
  ) async {
    final controller = ClientController()
      ..currentSection = ClientSection.settings
      ..scannedTargets = [_target('codex', 'ChatGPT Codex - CLI')]
      ..selectedConversationAgentId = ''
      ..selectedConversationSessionId = ''
      ..conversationSessionsByAgent = {
        'codex': [
          _session('c1', 'codex', 'Appearance notes', 'theme tokens live here'),
        ],
      };
    addTearDown(controller.dispose);

    final strings = LicoStrings.forLocale(const Locale('zh'));
    await _pumpPalette(
      tester,
      controller,
      features: buildGlobalSearchFeatures(
        strings: strings,
        onSelectSection: (_) {},
        onNewConversation: () {},
      ),
      settingsFeatures: buildSettingsSearchFeatures(
        strings: strings,
        onOpenSettings: () {},
      ),
    );

    await tester.enterText(
      find.byKey(const Key('conversation-search-palette-input')),
      'notarization-missing',
    );
    await tester.pump();

    expect(find.text('Appearance notes'), findsNothing);
    expect(find.text('没有匹配的对话'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('skill hub destination ranks skill hits above features', (
    tester,
  ) async {
    final controller = ClientController()
      ..currentSection = ClientSection.skillHub
      ..scannedTargets = [_target('codex', 'ChatGPT Codex - CLI')]
      ..selectedConversationAgentId = ''
      ..selectedConversationSessionId = ''
      ..skillHubSkills = const [
        {
          'skillId': 'stitch-design-taste',
          'title': 'stitch-design-taste',
          'description': 'Semantic Design System Skill for Google Stitch.',
          'isPublic': true,
        },
      ]
      ..conversationSessionsByAgent = {
        'codex': [_session('c1', 'codex', 'Skill cleanup', 'skill notes')],
      };
    addTearDown(controller.dispose);

    await _pumpPalette(
      tester,
      controller,
      features: buildGlobalSearchFeatures(
        strings: LicoStrings.forLocale(const Locale('zh')),
        onSelectSection: (_) {},
        onNewConversation: () {},
      ),
    );

    await tester.enterText(
      find.byKey(const Key('conversation-search-palette-input')),
      'skill',
    );
    await tester.pump();

    expect(
      tester.getTopLeft(find.text('stitch-design-taste')).dy,
      lessThan(tester.getTopLeft(find.text('功能')).dy),
    );
    expect(tester.takeException(), isNull);
  });
}

final class _SearchPaletteAgentService extends AgentService {
  @override
  Future<TargetScanBatch> scanTargetsBatch(
    List<String> targetIds, {
    bool enableAgentCliModelLookup = false,
  }) async => TargetScanBatch([
    for (final targetId in targetIds)
      TargetScanSlot(targetId: targetId, failed: true),
  ]);
}

TargetCandidate _target(String target, String label) {
  return TargetCandidate(
    target: target,
    label: label,
    kind: 'cli',
    status: 'detected',
    configured: true,
    confidence: 1,
    adapterStatus: 'implemented',
  );
}

AgentConversationSession _session(
  String id,
  String agentId,
  String title,
  String body,
) {
  final updatedAt = DateTime.now()
      .subtract(const Duration(days: 1))
      .toUtc()
      .toIso8601String();
  return AgentConversationSession(
    id: id,
    agentId: agentId,
    title: title,
    createdAt: updatedAt,
    updatedAt: updatedAt,
    messages: [
      AgentConversationMessage(
        id: '$id-m1',
        role: 'user',
        text: body,
        createdAt: updatedAt,
      ),
    ],
  );
}

Future<void> _pumpPalette(
  WidgetTester tester,
  ClientController controller, {
  VoidCallback? onClose,
  List<GlobalSearchFeatureEntry> features = const [],
  List<GlobalSearchFeatureEntry> settingsFeatures = const [],
}) async {
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
        body: SizedBox(
          width: 900,
          height: 640,
          child: AgentConversationSearchPalette(
            controller: controller,
            features: features,
            settingsFeatures: settingsFeatures,
            onClose: onClose ?? () {},
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}
