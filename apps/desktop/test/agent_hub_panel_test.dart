import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:licoup/src/application/features/agent_hub/agent_hub_engine.dart';
import 'package:licoup/src/application/features/agent_hub/agent_hub_catalog_controller.dart';
import 'package:licoup/src/contracts/agent_hub.dart';
import 'package:licoup/src/frontend/features/agent_hub/ui/agent_hub_panel.dart';
import 'package:licoup/src/frontend/features/agent_hub/ui/agent_hub_summary_visit.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/lico_pane_title_bar.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

const _ids = [
  'codex',
  'cursor',
  'opencode',
  'claude-code',
  'pi',
  'openclaw',
  'hermes',
  'antigravity',
  'deepseek-harness',
];

const _summaries = {
  'codex':
      'Codex CLI is a coding agent from OpenAI that runs locally on your computer.',
  'cursor':
      'Cursor is a coding agent for building ambitious software. Use it to understand your codebase, plan and build features, fix bugs, review changes, and work with the tools you already use.',
  'opencode':
      'OpenCode is an open source agent that helps you write code in your terminal, IDE, or desktop.',
  'claude-code':
      'Claude Code is an agentic coding tool that lives in your terminal, understands your codebase, and helps you code faster by executing routine tasks, explaining complex code, and handling git workflows',
  'pi':
      'Pi is a minimal agent harness. Adapt Pi to your workflows, not the other way around.',
  'openclaw': 'The AI that really does things.',
  'hermes': 'The self-improving AI agent built by Nous Research.',
  'antigravity': 'Experience liftoff with the next-gen agent platform.',
  'deepseek-harness':
      'DeepSeek Harness is an open-source agent harness. Everything is a plugin.',
};

const _homepages = {
  'codex': 'https://developers.openai.com/codex',
  'cursor': 'https://cursor.com',
  'opencode': 'https://opencode.ai',
  'claude-code': 'https://claude.com/product/claude-code',
  'pi': 'https://pi.dev',
  'openclaw': 'https://openclaw.ai',
  'hermes': 'https://hermes-agent.nousresearch.com',
  'antigravity': 'https://antigravity.google',
  'deepseek-harness': 'https://deepseek.com/harness/en/',
};

String _channelKind(String id) {
  return switch (id) {
    'pi' || 'openclaw' || 'deepseek-harness' => 'npm',
    'hermes' => 'official-artifact',
    _ => 'homebrew',
  };
}

String _title(String id) {
  return switch (id) {
    'codex' => 'Codex',
    'cursor' => 'Cursor',
    'antigravity' => 'Antigravity',
    'deepseek-harness' => 'DeepSeek Harness',
    _ => id,
  };
}

List<AgentHubInstallChannel> _channels(String id) {
  final kind = _channelKind(id);
  return [
    AgentHubInstallChannel(
      id: kind,
      kind: kind,
      officialSource: 'https://example.com/$id',
      commandPreview: kind == 'homebrew'
          ? 'brew install --cask $id'
          : kind == 'npm'
          ? 'npm install -g $id'
          : 'install $id',
    ),
    if (kind == 'homebrew')
      AgentHubInstallChannel(
        id: 'npm',
        kind: 'npm',
        officialSource: 'https://www.npmjs.com/package/$id',
        commandPreview: 'npm install -g $id',
      ),
  ];
}

List<AgentHubRecipe> _recipes({
  Set<String> presentIds = const {},
  Set<String> externalIds = const {},
  Set<String> externalProtectedIds = const {},
  Set<String> ownedIds = const {},
  Set<String> failedIds = const {},
  Set<String> updateAvailableIds = const {},
  Map<String, String> installedVersions = const {},
  Map<String, String> latestVersions = const {},
}) {
  return [
    for (final id in _ids)
      AgentHubRecipe(
        id: id,
        displayName: _title(id),
        adaptation: id == 'antigravity'
            ? AgentHubAdaptationDepth.partial
            : id == 'deepseek-harness'
            ? AgentHubAdaptationDepth.pendingEvaluation
            : AgentHubAdaptationDepth.deep,
        present:
            presentIds.contains(id) ||
            ownedIds.contains(id) ||
            externalIds.contains(id) ||
            externalProtectedIds.contains(id),
        ownership: ownedIds.contains(id)
            ? 'owned'
            : externalProtectedIds.contains(id)
            ? 'external_protected'
            : externalIds.contains(id)
            ? 'external'
            : 'none',
        lifecycle: failedIds.contains(id)
            ? 'failed'
            : presentIds.contains(id) ||
                  ownedIds.contains(id) ||
                  externalIds.contains(id) ||
                  externalProtectedIds.contains(id)
            ? 'discovered'
            : 'absent',
        installable:
            !externalIds.contains(id) && !externalProtectedIds.contains(id),
        channelKind: _channelKind(id),
        selectedChannelKind: _channelKind(id),
        summary: _summaries[id]!,
        homepage: _homepages[id]!,
        installedVersion: installedVersions[id] ?? '',
        latestVersion: latestVersions[id] ?? '',
        updateAvailable: updateAvailableIds.contains(id),
        version: installedVersions[id] ?? '',
        installChannels: _channels(id),
      ),
  ];
}

AgentHubCatalogSnapshot _snapshot({
  Set<String> presentIds = const {},
  Set<String> externalIds = const {},
  Set<String> externalProtectedIds = const {},
  Set<String> ownedIds = const {},
  Set<String> failedIds = const {},
  Set<String> updateAvailableIds = const {},
  Map<String, String> installedVersions = const {},
  Map<String, String> latestVersions = const {},
}) {
  return AgentHubCatalogSnapshot(
    recipes: _recipes(
      presentIds: presentIds,
      externalIds: externalIds,
      externalProtectedIds: externalProtectedIds,
      ownedIds: ownedIds,
      failedIds: failedIds,
      updateAvailableIds: updateAvailableIds,
      installedVersions: installedVersions,
      latestVersions: latestVersions,
    ),
  );
}

final class _FakeHubEngine implements AgentHubEnginePort {
  _FakeHubEngine({
    this.presentIds = const {},
    this.externalIds = const {},
    this.externalProtectedIds = const {},
    this.ownedIds = const {},
    this.failedIds = const {},
    this.updateAvailableIds = const {},
    this.installedVersions = const {},
    this.latestVersions = const {},
    this.seedCache,
    this.warehouseSnapshot,
    this.catalogFuture,
    Map<String, Completer<AgentHubCatalogSnapshot>>? inspectDelays,
  }) : inspectDelays = inspectDelays ?? {};

  final Set<String> presentIds;
  final Set<String> externalIds;
  final Set<String> externalProtectedIds;
  final Set<String> ownedIds;
  final Set<String> failedIds;
  final Set<String> updateAvailableIds;
  final Map<String, String> installedVersions;
  final Map<String, String> latestVersions;
  final AgentHubCatalogSnapshot? seedCache;
  final AgentHubCatalogSnapshot? warehouseSnapshot;
  final Future<AgentHubCatalogSnapshot>? catalogFuture;
  final Map<String, Completer<AgentHubCatalogSnapshot>> inspectDelays;
  final List<AgentHubLifecycleAction> actions = [];
  final List<String> catalogRecipeIds = [];
  String? lastRecipeId;
  String? lastChannelId;
  String? lastVersion;
  AgentHubCatalogSnapshot? _cache;

  AgentHubCatalogSnapshot get _liveSnapshot => _snapshot(
    presentIds: presentIds,
    externalIds: externalIds,
    externalProtectedIds: externalProtectedIds,
    ownedIds: ownedIds,
    failedIds: failedIds,
    updateAvailableIds: updateAvailableIds,
    installedVersions: installedVersions,
    latestVersions: latestVersions,
  );

  @override
  AgentHubCatalogSnapshot? get cachedCatalog => seedCache ?? _cache;

  @override
  Future<AgentHubCatalogSnapshot> catalog({String recipeId = ''}) async {
    catalogRecipeIds.add(recipeId);
    if (recipeId.isEmpty) {
      if (catalogFuture != null) {
        return catalogFuture!;
      }
      final snapshot = warehouseSnapshot ?? _liveSnapshot;
      _cache = snapshot;
      return snapshot;
    }
    final delay = inspectDelays[recipeId];
    if (delay != null) {
      await delay.future;
    }
    final live = _liveSnapshot.recipes
        .where((recipe) => recipe.id == recipeId)
        .toList();
    return AgentHubCatalogSnapshot(recipes: live, ok: live.isNotEmpty);
  }

  @override
  Future<AgentHubOperationResult> plan(AgentHubPlanRequest request) async {
    lastChannelId = request.channelId;
    lastVersion = request.version;
    return _record(AgentHubLifecycleAction.plan, request.recipeId, 'planned');
  }

  @override
  Future<AgentHubOperationResult> confirm(
    AgentHubConfirmRequest request,
  ) async {
    return _record(
      AgentHubLifecycleAction.confirm,
      request.recipeId,
      'confirmed',
    );
  }

  @override
  Future<AgentHubOperationResult> install(
    AgentHubInstallRequest request,
  ) async {
    lastChannelId = request.channelId;
    lastVersion = request.version;
    return _record(
      AgentHubLifecycleAction.install,
      request.recipeId,
      'available',
      events: const [
        'planned',
        'confirmed',
        'applying',
        'verifying',
        'rescanning',
        'available',
      ],
    );
  }

  @override
  Future<AgentHubOperationResult> update(AgentHubUpdateRequest request) async {
    return _record(
      AgentHubLifecycleAction.update,
      request.recipeId,
      'available',
    );
  }

  @override
  Future<AgentHubOperationResult> uninstall(
    AgentHubUninstallRequest request,
  ) async {
    return _record(
      AgentHubLifecycleAction.uninstall,
      request.recipeId,
      'uninstalled',
    );
  }

  @override
  Future<AgentHubOperationResult> verify(AgentHubVerifyRequest request) async {
    return _record(AgentHubLifecycleAction.verify, request.recipeId, 'absent');
  }

  @override
  Future<AgentHubOperationResult> rescan(AgentHubRescanRequest request) async {
    return _record(
      AgentHubLifecycleAction.rescan,
      request.recipeId,
      'absent',
      recipes: _liveSnapshot.recipes,
    );
  }

  AgentHubOperationResult _record(
    AgentHubLifecycleAction action,
    String recipeId,
    String nativeStatus, {
    List<String> events = const [],
    List<AgentHubRecipe> recipes = const [],
  }) {
    actions.add(action);
    lastRecipeId = recipeId;
    return AgentHubOperationResult(
      status: AgentHubOperationStatus.completed,
      action: action,
      recipeId: recipeId,
      nativeStatus: nativeStatus,
      events: events,
      recipes: recipes,
    );
  }
}

typedef _HubHarness = (Widget, AgentHubCatalogController);

_HubHarness _harness(
  AgentHubEnginePort engine, {
  Locale locale = const Locale('en'),
  AgentHubHomepageOpener? openHomepage,
  AgentHubOpenAgent? onOpenAgent,
}) {
  final controller = AgentHubCatalogController(engine: engine);
  return (
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
          width: 1000,
          height: 720,
          child: AgentHubPanel(
            controller: controller,
            orderRecipes: (recipes) => recipes,
            openHomepage: openHomepage ?? (uri) async => true,
            onOpenAgent: onOpenAgent,
          ),
        ),
      ),
    ),
    controller,
  );
}

Future<void> _openDetail(WidgetTester tester, String id) async {
  await tester.tap(find.byKey(Key('agent-hub-intro-$id')));
  await tester.pump();
}

Future<void> _pumpHub(WidgetTester tester, _HubHarness harness) async {
  final (app, controller) = harness;
  // Explicit application-owned preload before mount: the panel itself must
  // stay free of catalog I/O while rendering the controller projection.
  unawaited(controller.refresh());
  await tester.binding.setSurfaceSize(const Size(1000, 720));
  tester.view.devicePixelRatio = 1;
  addTearDown(() async {
    tester.view.resetDevicePixelRatio();
    await tester.binding.setSurfaceSize(null);
  });
  await tester.pumpWidget(app);
  await tester.pump();
  await tester.pump();
}

void main() {
  test('shuffleAgentHubRecipes keeps every supported agent exactly once', () {
    final recipes = _recipes();
    final shuffled = shuffleAgentHubRecipes(recipes);
    expect(shuffled.map((recipe) => recipe.id), unorderedEquals(_ids));
  });

  testWidgets('Agent Hub renders native portrait recipe cards', (tester) async {
    await _pumpHub(tester, _harness(_FakeHubEngine()));

    expect(find.byKey(const Key('agent-hub-panel')), findsOneWidget);
    expect(find.byKey(const Key('agent-hub-top-bar')), findsOneWidget);
    expect(find.byKey(const Key('agent-hub-refresh')), findsOneWidget);
    expect(find.byKey(const Key('agent-hub-search')), findsNothing);
    expect(find.byKey(const Key('agent-hub-back')), findsNothing);
    expect(find.text('Agent Hub'), findsOneWidget);
    expect(find.byType(LicoPaneTitleBar), findsOneWidget);
    for (final id in _ids) {
      expect(find.byKey(Key('agent-hub-card-$id')), findsOneWidget);
      expect(find.byKey(Key('agent-hub-intro-$id')), findsOneWidget);
      expect(find.byKey(Key('agent-hub-header-$id')), findsOneWidget);
      expect(find.byKey(Key('agent-hub-name-$id')), findsOneWidget);
      expect(find.byKey(Key('agent-hub-adaptation-$id')), findsNothing);
      expect(find.byKey(Key('agent-hub-summary-$id')), findsOneWidget);
      expect(find.byKey(Key('agent-hub-channel-$id')), findsNothing);
      expect(find.byKey(Key('agent-hub-version-$id')), findsNothing);
      expect(find.byKey(Key('agent-hub-visit-$id')), findsNothing);
      expect(find.byKey(Key('agent-hub-install-$id')), findsOneWidget);
      expect(find.byKey(Key('agent-hub-update-$id')), findsNothing);
      expect(find.byKey(Key('agent-hub-open-$id')), findsNothing);
      expect(find.byKey(Key('agent-hub-uninstall-$id')), findsNothing);
      expect(find.byKey(Key('agent-hub-status-$id')), findsNothing);
      expect(find.byKey(Key('agent-hub-more-$id')), findsNothing);
      final name = tester.widget<Text>(find.byKey(Key('agent-hub-name-$id')));
      expect(name.maxLines, 2);
      expect(name.overflow, TextOverflow.ellipsis);
      final summary = tester.widget<Text>(
        find.byKey(Key('agent-hub-summary-$id')),
      );
      expect(summary.maxLines, 3);
      expect(summary.overflow, TextOverflow.ellipsis);
      expect(summary.data, _summaries[id]);
      expect(summary.textSpan, isNull);
      final paragraph = tester.renderObject<RenderParagraph>(
        find.byKey(Key('agent-hub-summary-$id')),
      );
      expect(paragraph.maxLines, 3);
      final boxes = paragraph.getBoxesForSelection(
        TextSelection(
          baseOffset: 0,
          extentOffset: paragraph.text.toPlainText().length,
        ),
      );
      expect(_summaryLineCount(boxes), lessThanOrEqualTo(3));
      final headerRect = tester.getRect(
        find.byKey(Key('agent-hub-header-$id')),
      );
      final summaryRect = tester.getRect(
        find.byKey(Key('agent-hub-summary-$id')),
      );
      final introRect = tester.getRect(find.byKey(Key('agent-hub-intro-$id')));
      expect(summaryRect.top - headerRect.bottom, closeTo(0, 0.5));
      expect(introRect.bottom - summaryRect.bottom, closeTo(8, 0.5));
      expect(
        tester.widget<InkWell>(find.byKey(Key('agent-hub-install-$id'))).onTap,
        isNotNull,
      );
    }
    expect(find.text('Deep'), findsNothing);
    expect(find.text('Partial'), findsNothing);
    expect(find.text('Pending'), findsNothing);
    expect(find.text('Codex'), findsOneWidget);
    expect(find.text('Cursor'), findsOneWidget);
    expect(find.text('Antigravity'), findsOneWidget);
    expect(find.text('DeepSeek Harness'), findsOneWidget);
    expect(find.text('brew'), findsNothing);
    expect(find.text('npm'), findsNothing);
    expect(find.text('official'), findsNothing);
    expect(find.text('unknown'), findsNothing);
    expect(find.text('未知'), findsNothing);
    expect(find.text('latest'), findsNothing);
    expect(find.byIcon(Icons.open_in_new), findsNothing);
    expect(find.byTooltip('Visit site'), findsNothing);
    expect(find.text('Visit site'), findsNothing);
    expect(find.text('Install'), findsNWidgets(_ids.length));
    expect(find.text('Update'), findsNothing);
    expect(find.text('Chat'), findsNothing);
    expect(find.text('Open'), findsNothing);
    expect(find.text('Uninstall'), findsNothing);
    expect(find.text('Visit →'), findsNothing);
    expect(find.text('Installed'), findsNothing);
    expect(find.text('Not installed'), findsNothing);
    expect(find.text('External'), findsNothing);
    expect(find.text('Failed'), findsNothing);
    expect(find.textContaining('rank'), findsNothing);
    expect(find.textContaining('Code mode'), findsNothing);
    expect(
      tester.getRect(find.byKey(const Key('agent-hub-card-codex'))).height,
      closeTo(147.4, 0.5),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'interface entry refresh resolves live card state before enabling actions',
    (tester) async {
      final inspection = Completer<AgentHubCatalogSnapshot>();
      final engine = _FakeHubEngine(
        warehouseSnapshot: AgentHubCatalogSnapshot(
          recipes: [
            AgentHubRecipe(
              id: 'codex',
              displayName: 'Codex',
              adaptation: AgentHubAdaptationDepth.deep,
              installable: false,
              summary: _summaries['codex']!,
              homepage: _homepages['codex']!,
            ),
          ],
        ),
        inspectDelays: {'codex': inspection},
      );
      final harness = _harness(engine);
      unawaited(harness.$2.refresh());
      await tester.binding.setSurfaceSize(const Size(1000, 720));
      tester.view.devicePixelRatio = 1;
      addTearDown(() async {
        tester.view.resetDevicePixelRatio();
        await tester.binding.setSurfaceSize(null);
      });
      await tester.pumpWidget(harness.$1);
      await tester.pump();

      expect(engine.catalogRecipeIds, ['', 'codex']);
      expect(
        find.byKey(const Key('agent-hub-card-loading-codex')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<InkWell>(find.byKey(const Key('agent-hub-install-codex')))
            .onTap,
        isNull,
      );

      inspection.complete(_snapshot());
      await tester.pump();
      await tester.pump();

      expect(
        find.byKey(const Key('agent-hub-card-loading-codex')),
        findsNothing,
      );
      expect(
        tester
            .widget<InkWell>(find.byKey(const Key('agent-hub-install-codex')))
            .onTap,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('intro opens the agent detail and back returns to the catalog', (
    tester,
  ) async {
    await _pumpHub(tester, _harness(_FakeHubEngine()));

    await _openDetail(tester, 'codex');
    expect(find.byKey(const Key('agent-hub-detail-codex')), findsOneWidget);
    expect(find.byKey(const Key('agent-hub-card-codex')), findsNothing);
    expect(find.byKey(const Key('agent-hub-back')), findsOneWidget);
    expect(find.text('Agent Hub'), findsNothing);
    expect(find.text('Codex'), findsWidgets);
    expect(find.byKey(const Key('agent-hub-adaptation-codex')), findsOneWidget);
    expect(find.text('Deep'), findsOneWidget);
    expect(find.byKey(const Key('agent-hub-visit-codex')), findsOneWidget);
    expect(find.byKey(const Key('agent-hub-channel-codex')), findsOneWidget);
    expect(find.byKey(const Key('agent-hub-uninstall-codex')), findsOneWidget);
    expect(find.text('Install'), findsOneWidget);
    expect(find.text('Update'), findsOneWidget);
    expect(find.text('Chat'), findsOneWidget);
    expect(find.text('Open'), findsNothing);
    expect(find.text('Uninstall'), findsOneWidget);

    await tester.tap(find.byKey(const Key('agent-hub-back')));
    await tester.pump();
    expect(find.byKey(const Key('agent-hub-detail-codex')), findsNothing);
    expect(find.byKey(const Key('agent-hub-card-codex')), findsOneWidget);
    expect(find.byKey(const Key('agent-hub-back')), findsNothing);
    expect(find.text('Agent Hub'), findsOneWidget);
    expect(find.text('Uninstall'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Chat on an installed card selects that conversation agent', (
    tester,
  ) async {
    final opened = <String>[];
    await _pumpHub(
      tester,
      _harness(
        _FakeHubEngine(ownedIds: const {'codex'}),
        onOpenAgent: opened.add,
      ),
    );

    await tester.tap(find.byKey(const Key('agent-hub-open-codex')));
    await tester.pump();
    expect(opened, ['codex']);
    expect(find.byKey(const Key('agent-hub-detail-codex')), findsNothing);
    expect(find.byKey(const Key('agent-hub-card-codex')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('footer actions do not open the agent detail page', (
    tester,
  ) async {
    await _pumpHub(tester, _harness(_FakeHubEngine()));

    await tester.tap(find.byKey(const Key('agent-hub-install-codex')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('agent-hub-detail-codex')), findsNothing);
    expect(find.byKey(const Key('agent-hub-install-dialog')), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('agent-hub-detail-codex')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('description keeps visit on the last visible line', (
    tester,
  ) async {
    await _pumpHub(tester, _harness(_FakeHubEngine()));
    await _openDetail(tester, 'cursor');

    final summary = tester.getRect(
      find.byKey(const Key('agent-hub-summary-cursor')),
    );
    final visit = tester.getRect(
      find.byKey(const Key('agent-hub-visit-cursor')),
    );
    final paragraph = tester.renderObject<RenderParagraph>(
      find.byKey(const Key('agent-hub-summary-cursor')),
    );
    final boxes = paragraph.getBoxesForSelection(
      TextSelection(
        baseOffset: 0,
        extentOffset: paragraph.text.toPlainText().length,
      ),
    );
    expect(
      _summaryLineCount(boxes),
      lessThanOrEqualTo(AgentHubSummaryVisit.maxLines),
    );
    expect(paragraph.maxLines, AgentHubSummaryVisit.maxLines);
    expect(paragraph.text.toPlainText(), contains('...'));
    expect(visit.top, greaterThanOrEqualTo(summary.top - 2));
    expect(visit.bottom, lessThanOrEqualTo(summary.bottom + 4));
    expect(visit.left, greaterThan(summary.left));
    expect(visit.height, lessThan(24));
    expect(tester.takeException(), isNull);
  });

  testWidgets('package-manager chip and version share one centerline', (
    tester,
  ) async {
    await _pumpHub(
      tester,
      _harness(
        _FakeHubEngine(
          ownedIds: const {'codex'},
          installedVersions: const {'codex': '0.147.0'},
        ),
      ),
    );
    await _openDetail(tester, 'codex');

    final chip = tester.getRect(
      find.byKey(const Key('agent-hub-channel-codex')),
    );
    final version = tester.getRect(
      find.byKey(const Key('agent-hub-version-codex')),
    );
    expect(chip.center.dy, closeTo(version.center.dy, 1));
    expect(
      find.byKey(const Key('agent-hub-channel-version-codex')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Agent Hub Visit label follows LicoStrings locale', (
    tester,
  ) async {
    await _pumpHub(
      tester,
      _harness(_FakeHubEngine(), locale: const Locale('zh')),
    );
    await tester.pump();
    expect(find.byIcon(Icons.open_in_new), findsNothing);
    expect(find.byTooltip('访问官网'), findsNothing);
    expect(find.text('访问官网'), findsNothing);
    expect(find.text('安装'), findsNWidgets(_ids.length));
    expect(find.text('更新'), findsNothing);
    expect(find.text('对话'), findsNothing);
    expect(find.text('打开'), findsNothing);
    expect(find.text('访问'), findsNothing);
    expect(find.text('Visit →'), findsNothing);
    expect(find.text('卸载'), findsNothing);
    expect(find.text('外部安装'), findsNothing);
    expect(find.text('未安装'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Visit opens the official homepage through the injected opener', (
    tester,
  ) async {
    final opened = <Uri>[];
    await _pumpHub(
      tester,
      _harness(
        _FakeHubEngine(),
        openHomepage: (uri) async {
          opened.add(uri);
          return true;
        },
      ),
    );
    await _openDetail(tester, 'codex');
    await tester.tap(find.byKey(const Key('agent-hub-visit-codex')));
    await tester.pump();
    expect(opened, [Uri.parse('https://developers.openai.com/codex')]);
    expect(find.text('Unable to open homepage'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Visit fail-closed shows a visible error instead of no-op', (
    tester,
  ) async {
    await _pumpHub(
      tester,
      _harness(_FakeHubEngine(), openHomepage: (uri) async => false),
    );
    await tester.pump();
    await _openDetail(tester, 'codex');
    await tester.tap(find.byKey(const Key('agent-hub-visit-codex')));
    await tester.pump();
    expect(find.text('Unable to open homepage'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('pane refresh lives in the top bar and rediscovers every card', (
    tester,
  ) async {
    final engine = _FakeHubEngine();
    await _pumpHub(tester, _harness(engine, locale: const Locale('zh')));
    expect(find.byKey(const Key('agent-hub-more-codex')), findsNothing);
    expect(find.text('安装计划'), findsNothing);
    expect(find.text('重新扫描'), findsNothing);
    expect(find.byKey(const Key('agent-hub-top-bar')), findsOneWidget);
    expect(find.byKey(const Key('agent-hub-refresh')), findsOneWidget);
    expect(find.byKey(const Key('agent-hub-search')), findsNothing);
    expect(find.text('智能体中心'), findsOneWidget);
    final topBar = tester.getRect(find.byKey(const Key('agent-hub-top-bar')));
    final refresh = tester.getRect(find.byKey(const Key('agent-hub-refresh')));
    final title = tester.getRect(find.text('智能体中心'));
    expect(refresh.top, greaterThanOrEqualTo(topBar.top));
    expect(refresh.bottom, lessThanOrEqualTo(topBar.bottom));
    expect((title.center.dy - refresh.center.dy).abs(), lessThan(1));
    expect(
      refresh.right,
      closeTo(topBar.right - LicoContentSpacing.paneInset, 1),
    );
    expect(refresh.left, greaterThan(title.right));
    engine.catalogRecipeIds.clear();
    await tester.tap(find.byKey(const Key('agent-hub-refresh')));
    await tester.pump();
    await tester.pump();
    expect(engine.actions, isEmpty);
    expect(engine.catalogRecipeIds.where((id) => id.isEmpty), hasLength(1));
    expect(
      engine.catalogRecipeIds.where((id) => id.isNotEmpty).toSet(),
      _ids.toSet(),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Agent Hub panel joins plan/confirm/install/verify/rescan through the native port',
    (tester) async {
      final engine = _FakeHubEngine();
      await _pumpHub(tester, _harness(engine));

      final panel = tester.widget<AgentHubPanel>(find.byType(AgentHubPanel));
      final plan = await panel.runLifecycle(
        AgentHubLifecycleAction.plan,
        recipeId: 'codex',
      );
      final confirm = await panel.runLifecycle(
        AgentHubLifecycleAction.confirm,
        recipeId: 'codex',
      );
      final install = await panel.runLifecycle(
        AgentHubLifecycleAction.install,
        recipeId: 'codex',
      );
      final verify = await panel.runLifecycle(
        AgentHubLifecycleAction.verify,
        recipeId: 'cursor',
      );
      final rescan = await panel.runLifecycle(
        AgentHubLifecycleAction.rescan,
        recipeId: 'opencode',
      );
      final update = await panel.runLifecycle(
        AgentHubLifecycleAction.update,
        recipeId: 'codex',
      );
      final uninstall = await panel.runLifecycle(
        AgentHubLifecycleAction.uninstall,
        recipeId: 'codex',
      );
      expect(plan.status, AgentHubOperationStatus.completed);
      expect(confirm.status, AgentHubOperationStatus.completed);
      expect(install.status, AgentHubOperationStatus.completed);
      expect(verify.status, AgentHubOperationStatus.completed);
      expect(rescan.status, AgentHubOperationStatus.completed);
      expect(update.status, AgentHubOperationStatus.completed);
      expect(uninstall.status, AgentHubOperationStatus.completed);
      expect(engine.actions, [
        AgentHubLifecycleAction.plan,
        AgentHubLifecycleAction.confirm,
        AgentHubLifecycleAction.install,
        AgentHubLifecycleAction.verify,
        AgentHubLifecycleAction.rescan,
        AgentHubLifecycleAction.update,
        AgentHubLifecycleAction.uninstall,
      ]);
    },
  );

  testWidgets('list card footer fills the area below the divider', (
    tester,
  ) async {
    await _pumpHub(tester, _harness(_FakeHubEngine(ownedIds: const {'codex'})));
    await tester.pump();

    final listCard = tester.getRect(
      find.byKey(const Key('agent-hub-card-codex')),
    );
    final open = tester.getRect(find.byKey(const Key('agent-hub-open-codex')));
    expect(open.left, closeTo(listCard.left, 0.5));
    expect(open.right, closeTo(listCard.right, 0.5));
    expect(open.bottom, closeTo(listCard.bottom, 0.5));
    expect(open.height, closeTo(36, 1));
    expect(find.byType(Divider), findsNWidgets(_ids.length));
    expect(find.byKey(const Key('agent-hub-install-codex')), findsNothing);
    expect(find.byKey(const Key('agent-hub-update-codex')), findsNothing);
    expect(find.byKey(const Key('agent-hub-uninstall-codex')), findsNothing);

    await _openDetail(tester, 'codex');
    final detail = tester.getRect(
      find.byKey(const Key('agent-hub-detail-codex')),
    );
    final chip = tester.getRect(
      find.byKey(const Key('agent-hub-channel-codex')),
    );
    final detailInstall = tester.getRect(
      find.byKey(const Key('agent-hub-install-codex')),
    );
    final update = tester.getRect(
      find.byKey(const Key('agent-hub-update-codex')),
    );
    final uninstall = tester.getRect(
      find.byKey(const Key('agent-hub-uninstall-codex')),
    );
    expect(chip.left - detail.left, closeTo(LicoContentSpacing.item, 0.5));
    expect(
      detailInstall.left - detail.left,
      closeTo(LicoContentSpacing.item, 0.5),
    );
    expect(
      detail.bottom - uninstall.bottom,
      closeTo(LicoContentSpacing.compact, 1),
    );
    expect(uninstall.left, greaterThan(update.right));
    expect(tester.takeException(), isNull);
  });

  testWidgets('unwired hub engine does not render a Dart recipe catalog', (
    tester,
  ) async {
    await _pumpHub(tester, _harness(const UnwiredAgentHubEngine()));
    expect(find.byKey(const Key('agent-hub-card-codex')), findsNothing);
    expect(find.byKey(const Key('agent-hub-catalog-failed')), findsOneWidget);
    expect(find.text('Scanning...'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'idle Hub cards show terminal presence instead of perpetual scanning',
    (tester) async {
      await _pumpHub(
        tester,
        _harness(
          _FakeHubEngine(
            presentIds: const {'codex'},
            externalIds: const {'cursor'},
            failedIds: const {'pi'},
          ),
          locale: const Locale('zh'),
        ),
      );
      await tester.pump();

      expect(find.text('扫描中...'), findsNothing);
      expect(find.byKey(const Key('agent-hub-card-busy')), findsNothing);
      expect(find.text('已安装'), findsNothing);
      expect(find.text('外部安装'), findsNothing);
      expect(find.text('失败'), findsNothing);
      expect(find.text('未安装'), findsNothing);
      expect(find.text('brew'), findsNothing);
      expect(find.text('npm'), findsNothing);
      expect(find.text('official'), findsNothing);
      expect(find.byKey(const Key('agent-hub-more-codex')), findsNothing);
      expect(find.byKey(const Key('agent-hub-open-codex')), findsOneWidget);
      expect(find.byKey(const Key('agent-hub-update-codex')), findsNothing);
      expect(find.byKey(const Key('agent-hub-install-codex')), findsNothing);
      expect(find.byKey(const Key('agent-hub-uninstall-codex')), findsNothing);
      expect(
        tester
            .widget<InkWell>(find.byKey(const Key('agent-hub-open-codex')))
            .onTap,
        isNotNull,
      );
      expect(find.byKey(const Key('agent-hub-open-cursor')), findsOneWidget);
      expect(find.byKey(const Key('agent-hub-update-cursor')), findsNothing);
      expect(find.byKey(const Key('agent-hub-install-cursor')), findsNothing);
      expect(find.byKey(const Key('agent-hub-uninstall-cursor')), findsNothing);
      expect(find.text('安装'), findsNWidgets(_ids.length - 2));
      expect(find.text('更新'), findsNothing);
      expect(find.text('对话'), findsNWidgets(2));
      expect(find.text('打开'), findsNothing);
      expect(find.text('卸载'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'present cards show update and uninstall even when ownership is external',
    (tester) async {
      final engine = _FakeHubEngine(
        presentIds: const {'codex', 'cursor', 'opencode'},
        ownedIds: const {'codex'},
        externalIds: const {'cursor'},
        externalProtectedIds: const {'opencode'},
        installedVersions: const {'codex': '1.2.3'},
      );
      await _pumpHub(tester, _harness(engine));

      expect(find.byKey(const Key('agent-hub-open-codex')), findsOneWidget);
      expect(find.byKey(const Key('agent-hub-open-cursor')), findsOneWidget);
      expect(find.byKey(const Key('agent-hub-open-opencode')), findsOneWidget);
      expect(find.byKey(const Key('agent-hub-install-codex')), findsNothing);
      expect(find.byKey(const Key('agent-hub-update-codex')), findsNothing);
      expect(find.text('1.2.3'), findsNothing);
      expect(find.text('latest'), findsNothing);
      expect(find.text('Install'), findsNWidgets(_ids.length - 3));
      expect(find.text('Update'), findsNothing);
      expect(find.text('Chat'), findsNWidgets(3));
      expect(find.text('Open'), findsNothing);
      expect(find.text('Uninstall'), findsNothing);
      for (final id in ['codex', 'cursor', 'opencode']) {
        expect(find.byKey(Key('agent-hub-open-$id')), findsOneWidget);
        expect(find.byKey(Key('agent-hub-install-$id')), findsNothing);
        expect(find.byKey(Key('agent-hub-update-$id')), findsNothing);
        expect(find.byKey(Key('agent-hub-uninstall-$id')), findsNothing);
        expect(
          tester.widget<InkWell>(find.byKey(Key('agent-hub-open-$id'))).onTap,
          isNotNull,
        );
      }
      expect(find.text('External'), findsNothing);
      expect(
        find.descendant(
          of: find.byKey(const Key('agent-hub-open-codex')),
          matching: find.byIcon(Icons.chat_bubble_outline),
        ),
        findsOneWidget,
      );

      await _openDetail(tester, 'codex');
      expect(find.text('1.2.3'), findsOneWidget);
      expect(
        find.byKey(const Key('agent-hub-uninstall-codex')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<InkWell>(find.byKey(const Key('agent-hub-uninstall-codex')))
            .onTap,
        isNotNull,
      );
      expect(
        tester
            .widget<InkWell>(find.byKey(const Key('agent-hub-uninstall-codex')))
            .borderRadius,
        const BorderRadius.all(Radius.circular(999)),
      );
      expect(
        (tester
                    .widget<Container>(
                      find.byKey(const Key('agent-hub-channel-codex')),
                    )
                    .decoration
                as BoxDecoration)
            .borderRadius,
        const BorderRadius.all(Radius.circular(999)),
      );
      expect(
        find.descendant(
          of: find.byKey(const Key('agent-hub-uninstall-codex')),
          matching: find.byIcon(Icons.delete_outline),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('absent cards leave version blank and never show 未知', (
    tester,
  ) async {
    await _pumpHub(
      tester,
      _harness(
        _FakeHubEngine(
          ownedIds: const {'codex'},
          installedVersions: const {'codex': '0.147.0'},
        ),
        locale: const Locale('zh'),
      ),
    );

    expect(find.text('0.147.0'), findsNothing);
    expect(find.byKey(const Key('agent-hub-version-codex')), findsNothing);
    await _openDetail(tester, 'codex');
    expect(find.text('0.147.0'), findsOneWidget);
    expect(find.byKey(const Key('agent-hub-version-codex')), findsOneWidget);
    expect(find.byKey(const Key('agent-hub-version-cursor')), findsNothing);
    expect(find.text('未知'), findsNothing);
    expect(find.text('unknown'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'cache paints immediately then locks actions until each card resolves',
    (tester) async {
      final pending = Completer<AgentHubCatalogSnapshot>();
      final cached = _snapshot(ownedIds: const {'codex'});
      final inspectDelays = {
        for (final id in _ids) id: Completer<AgentHubCatalogSnapshot>(),
      };
      final engine = _FakeHubEngine(
        ownedIds: const {'codex'},
        seedCache: cached,
        catalogFuture: pending.future,
        inspectDelays: inspectDelays,
      );
      await tester.binding.setSurfaceSize(const Size(1000, 720));
      tester.view.devicePixelRatio = 1;
      addTearDown(() async {
        tester.view.resetDevicePixelRatio();
        await tester.binding.setSurfaceSize(null);
      });
      final harness = _harness(engine);
      await tester.pumpWidget(harness.$1);
      await tester.pump();

      // The cached projection paints immediately; the explicit refresh locks
      // every card behind the pending catalog and per-card inspections.
      await tester.tap(find.byKey(const Key('agent-hub-refresh')));
      await tester.pump();

      expect(find.byKey(const Key('agent-hub-card-codex')), findsOneWidget);
      expect(find.byKey(const Key('agent-hub-loading')), findsNothing);
      expect(find.byKey(const Key('agent-hub-top-bar')), findsOneWidget);
      expect(
        find.byKey(const Key('agent-hub-card-loading-codex')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('agent-hub-update-codex')), findsNothing);
      expect(
        tester
            .widget<InkWell>(find.byKey(const Key('agent-hub-open-codex')))
            .onTap,
        isNull,
      );
      expect(find.byKey(const Key('agent-hub-uninstall-codex')), findsNothing);
      expect(
        tester
            .widget<InkWell>(find.byKey(const Key('agent-hub-install-cursor')))
            .onTap,
        isNull,
      );

      pending.complete(cached);
      await tester.pump();
      await tester.pump();
      inspectDelays['codex']!.complete(
        AgentHubCatalogSnapshot(
          recipes: cached.recipes
              .where((recipe) => recipe.id == 'codex')
              .toList(),
          ok: true,
        ),
      );
      await tester.pump();
      await tester.pump();

      expect(
        find.byKey(const Key('agent-hub-card-loading-codex')),
        findsNothing,
      );
      expect(find.byKey(const Key('agent-hub-update-codex')), findsNothing);
      expect(
        tester
            .widget<InkWell>(find.byKey(const Key('agent-hub-open-codex')))
            .onTap,
        isNotNull,
      );
      expect(find.byKey(const Key('agent-hub-uninstall-codex')), findsNothing);
      expect(
        tester
            .widget<InkWell>(find.byKey(const Key('agent-hub-install-cursor')))
            .onTap,
        isNull,
      );
      expect(
        find.byKey(const Key('agent-hub-card-loading-cursor')),
        findsOneWidget,
      );

      inspectDelays['cursor']!.complete(
        AgentHubCatalogSnapshot(
          recipes: _snapshot().recipes
              .where((recipe) => recipe.id == 'cursor')
              .toList(),
          ok: true,
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(
        find.byKey(const Key('agent-hub-card-loading-cursor')),
        findsNothing,
      );
      expect(
        tester
            .widget<InkWell>(find.byKey(const Key('agent-hub-install-cursor')))
            .onTap,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'update stays disabled when native says updateAvailable is false',
    (tester) async {
      await _pumpHub(
        tester,
        _harness(
          _FakeHubEngine(
            ownedIds: const {'codex'},
            installedVersions: const {'codex': '0.42.1'},
            latestVersions: const {'codex': '0.42.1'},
          ),
        ),
      );

      expect(find.text('0.42.1'), findsNothing);
      expect(find.text('latest'), findsNothing);
      expect(find.byKey(const Key('agent-hub-update-codex')), findsNothing);
      expect(
        tester
            .widget<InkWell>(find.byKey(const Key('agent-hub-open-codex')))
            .onTap,
        isNotNull,
      );
      expect(find.byKey(const Key('agent-hub-uninstall-codex')), findsNothing);

      await _openDetail(tester, 'codex');
      expect(find.text('0.42.1'), findsOneWidget);
      expect(
        tester
            .widget<InkWell>(find.byKey(const Key('agent-hub-uninstall-codex')))
            .onTap,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('update is tappable only when native updateAvailable is true', (
    tester,
  ) async {
    final engine = _FakeHubEngine(
      ownedIds: const {'codex'},
      updateAvailableIds: const {'codex'},
      installedVersions: const {'codex': '0.42.1'},
      latestVersions: const {'codex': '0.43.0'},
    );
    await _pumpHub(tester, _harness(engine));

    expect(find.text('0.42.1'), findsNothing);
    expect(find.text('latest'), findsNothing);
    expect(find.byKey(const Key('agent-hub-open-codex')), findsNothing);
    expect(find.byKey(const Key('agent-hub-install-codex')), findsNothing);
    expect(
      tester
          .widget<InkWell>(find.byKey(const Key('agent-hub-update-codex')))
          .onTap,
      isNotNull,
    );
    await tester.tap(find.byKey(const Key('agent-hub-update-codex')));
    await tester.pump();
    expect(find.byKey(const Key('agent-hub-detail-codex')), findsNothing);
    expect(engine.actions, [AgentHubLifecycleAction.update]);
    expect(engine.lastRecipeId, 'codex');
    expect(tester.takeException(), isNull);
  });

  testWidgets('uninstall requires the typed display name before apply', (
    tester,
  ) async {
    final engine = _FakeHubEngine(ownedIds: const {'codex'});
    await _pumpHub(tester, _harness(engine, locale: const Locale('zh')));
    await _openDetail(tester, 'codex');

    await tester.tap(find.byKey(const Key('agent-hub-uninstall-codex')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('agent-hub-uninstall-dialog')), findsOneWidget);
    expect(find.text('请输入 Codex 以确认'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('agent-hub-uninstall-confirm')),
          )
          .onPressed,
      isNull,
    );
    expect(engine.actions, isEmpty);

    await tester.enterText(
      find.byKey(const Key('agent-hub-uninstall-name-field')),
      'cursor',
    );
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('agent-hub-uninstall-confirm')),
          )
          .onPressed,
      isNull,
    );

    await tester.enterText(
      find.byKey(const Key('agent-hub-uninstall-name-field')),
      'Codex',
    );
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('agent-hub-uninstall-confirm')),
          )
          .onPressed,
      isNotNull,
    );
    await tester.tap(find.byKey(const Key('agent-hub-uninstall-confirm')));
    await tester.pump();
    expect(engine.actions, [AgentHubLifecycleAction.uninstall]);
    expect(engine.lastRecipeId, 'codex');
    expect(tester.takeException(), isNull);
  });

  testWidgets('install picker defaults to latest then confirms before apply', (
    tester,
  ) async {
    final engine = _FakeHubEngine();
    await _pumpHub(tester, _harness(engine));

    await tester.tap(find.byKey(const Key('agent-hub-install-codex')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('agent-hub-install-dialog')), findsOneWidget);
    expect(find.text('Download source'), findsOneWidget);
    expect(find.text('Command to run'), findsOneWidget);
    expect(find.text('https://example.com/codex'), findsOneWidget);
    expect(find.text('brew install --cask codex'), findsOneWidget);
    final versionField = tester.widget<DropdownButtonFormField<String>>(
      find.byKey(const Key('agent-hub-install-version')),
    );
    expect(versionField.initialValue, 'latest');
    await tester.tap(find.byKey(const Key('agent-hub-install-continue')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('agent-hub-install-confirm-dialog')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('agent-hub-install-confirm')));
    await tester.pump();
    expect(engine.actions, [
      AgentHubLifecycleAction.plan,
      AgentHubLifecycleAction.confirm,
      AgentHubLifecycleAction.install,
    ]);
    expect(engine.lastRecipeId, 'codex');
    expect(engine.lastChannelId, 'homebrew');
    expect(engine.lastVersion, 'latest');
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'cards stay on cached catalog when a later refresh never completes',
    (tester) async {
      final pending = Completer<AgentHubCatalogSnapshot>();
      await _pumpHub(
        tester,
        _harness(
          _FakeHubEngine(seedCache: _snapshot(), catalogFuture: pending.future),
          locale: const Locale('zh'),
        ),
      );

      expect(find.byKey(const Key('agent-hub-card-codex')), findsOneWidget);
      expect(find.text('扫描中...'), findsNothing);
      expect(find.byKey(const Key('agent-hub-card-busy')), findsNothing);
      expect(find.text('未安装'), findsNothing);
      expect(find.text('外部安装'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('failed catalog leaves scanning and shows a failure', (
    tester,
  ) async {
    await _pumpHub(
      tester,
      _harness(const _FailedCatalogEngine(), locale: const Locale('zh')),
    );

    expect(find.byKey(const Key('agent-hub-loading')), findsNothing);
    expect(find.byKey(const Key('agent-hub-catalog-failed')), findsOneWidget);
    expect(find.text('扫描中...'), findsNothing);
    expect(find.byKey(const Key('agent-hub-card-codex')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('thrown catalog leaves scanning and shows a failure', (
    tester,
  ) async {
    await _pumpHub(
      tester,
      _harness(const _ThrowingCatalogEngine(), locale: const Locale('zh')),
    );

    expect(find.byKey(const Key('agent-hub-catalog-failed')), findsOneWidget);
    expect(find.text('扫描中...'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}

AgentHubOperationResult _stubResult(
  AgentHubLifecycleAction action,
  String recipeId,
) {
  return AgentHubOperationResult(
    status: AgentHubOperationStatus.failed,
    action: action,
    recipeId: recipeId,
    nativeStatus: 'failed',
    events: const ['failed'],
  );
}

mixin _StubHubCatalog implements AgentHubEnginePort {
  @override
  AgentHubCatalogSnapshot? get cachedCatalog => null;

  @override
  Future<AgentHubOperationResult> plan(AgentHubPlanRequest request) async {
    return _stubResult(AgentHubLifecycleAction.plan, request.recipeId);
  }

  @override
  Future<AgentHubOperationResult> confirm(
    AgentHubConfirmRequest request,
  ) async {
    return _stubResult(AgentHubLifecycleAction.confirm, request.recipeId);
  }

  @override
  Future<AgentHubOperationResult> install(
    AgentHubInstallRequest request,
  ) async {
    return _stubResult(AgentHubLifecycleAction.install, request.recipeId);
  }

  @override
  Future<AgentHubOperationResult> update(AgentHubUpdateRequest request) async {
    return _stubResult(AgentHubLifecycleAction.update, request.recipeId);
  }

  @override
  Future<AgentHubOperationResult> uninstall(
    AgentHubUninstallRequest request,
  ) async {
    return _stubResult(AgentHubLifecycleAction.uninstall, request.recipeId);
  }

  @override
  Future<AgentHubOperationResult> verify(AgentHubVerifyRequest request) async {
    return _stubResult(AgentHubLifecycleAction.verify, request.recipeId);
  }

  @override
  Future<AgentHubOperationResult> rescan(AgentHubRescanRequest request) async {
    return _stubResult(AgentHubLifecycleAction.rescan, request.recipeId);
  }
}

final class _FailedCatalogEngine
    with _StubHubCatalog
    implements AgentHubEnginePort {
  const _FailedCatalogEngine();

  @override
  Future<AgentHubCatalogSnapshot> catalog({String recipeId = ''}) async {
    return const AgentHubCatalogSnapshot(recipes: [], ok: false);
  }
}

final class _ThrowingCatalogEngine
    with _StubHubCatalog
    implements AgentHubEnginePort {
  const _ThrowingCatalogEngine();

  @override
  Future<AgentHubCatalogSnapshot> catalog({String recipeId = ''}) async {
    throw StateError('native catalog failed');
  }
}

int _summaryLineCount(List<TextBox> boxes) {
  final tops = boxes.map((box) => box.top).toList()..sort();
  var count = 0;
  var last = -100.0;
  for (final top in tops) {
    if (top - last > AgentHubSummaryVisit.fontSize) {
      count++;
      last = top;
    }
  }
  return count;
}
