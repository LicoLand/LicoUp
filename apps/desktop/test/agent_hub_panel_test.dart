import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support/bundled_font_loader.dart';
import 'package:presentation_contract/presentation_contract.dart';
import 'package:licoup/src/composition/features/semantic_feature_channel.dart';
import 'package:licoup/src/presentation/plugin_management/plugin_management_binding.dart';
import 'package:licoup/src/presentation/plugin_management/plugin_management_effect.dart';
import 'package:licoup/src/presentation/plugin_management/plugin_management_intent.dart';
import 'package:licoup/src/presentation/plugin_management/plugin_management_projection.dart';
import 'package:licoup/src/presentation/skill_hub/skill_hub_binding.dart';
import 'package:licoup/src/presentation/skill_hub/skill_hub_projection.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';
import 'fixtures/skill_hub_binding_fixture.dart';

import 'package:licoup/src/application/features/agent_hub/agent_hub_engine.dart';
import 'package:licoup/src/application/features/agent_hub/agent_hub_catalog_controller.dart';
import 'package:licoup/src/contracts/agent_hub.dart';
import 'package:licoup/src/frontend/features/agent_hub/ui/agent_hub_panel.dart';
import 'package:licoup/src/frontend/features/agent_hub/ui/agent_hub_detail_tabs.dart';
import 'package:licoup/src/frontend/features/skill_hub/ui/skill_hub_panel.dart';
import 'package:licoup/src/presentation/skill_hub/skill_hub_intent.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/lico_pane_title_bar.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/agent_hub/agent_hub_projection.dart';

import 'fixtures/agent_hub_renderer_binding_fixture.dart';

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
    this.liveSnapshot,
    this.catalogFuture,
    this.lifecycleGate,
    this.liveDelay,
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

  /// When set, the batched live pass answers with this snapshot instead of the
  /// full one, so tests can drive a partial or failed batch.
  final AgentHubCatalogSnapshot? liveSnapshot;
  final Future<AgentHubCatalogSnapshot>? catalogFuture;

  /// When set, the install lifecycle step waits on this completer so tests
  /// can observe the in-progress UI before the operation effect arrives.
  final Completer<void>? lifecycleGate;
  final Map<String, Completer<AgentHubCatalogSnapshot>> inspectDelays;

  /// When set, the batched live root call waits on this completer so tests can
  /// observe the resolution window.
  final Completer<void>? liveDelay;
  final List<AgentHubLifecycleAction> actions = [];
  final List<String> catalogRecipeIds = [];

  /// Number of root calls that asked for the batched live resolution.
  int liveRootRequests = 0;
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
  Future<AgentHubCatalogSnapshot> catalog({
    String recipeId = '',
    bool live = false,
  }) async {
    catalogRecipeIds.add(recipeId);
    if (recipeId.isEmpty) {
      if (live) {
        liveRootRequests += 1;
        final gate = liveDelay;
        if (gate != null) {
          await gate.future;
        }
        final partial = liveSnapshot;
        if (partial != null) {
          _cache = partial;
          return partial;
        }
        // The batched live pass resolves the real card state; the static
        // warehouse snapshot only serves the first paint.
        _cache = _liveSnapshot;
        return _liveSnapshot;
      }
      if (catalogFuture != null) {
        return catalogFuture!;
      }
      final snapshot = warehouseSnapshot ?? _liveSnapshot;
      _cache = snapshot;
      return snapshot;
    }
    if (liveDelay != null) await liveDelay!.future;
    final delay = inspectDelays[recipeId];
    if (delay != null) {
      return delay.future;
    }
    final resolved = (liveSnapshot ?? _liveSnapshot).recipes
        .where((recipe) => recipe.id == recipeId)
        .toList();
    return AgentHubCatalogSnapshot(recipes: resolved, ok: resolved.isNotEmpty);
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
    final gate = lifecycleGate;
    if (gate != null) {
      await gate.future;
    }
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
typedef _AgentHubCatalogOrder =
    List<AgentHubEntryProjection> Function(
      List<AgentHubEntryProjection> entries,
    );

_HubHarness _harness(
  AgentHubEnginePort engine, {
  Locale locale = const Locale('en'),
  AgentHubExternalOpener? openHomepage,
  ValueChanged<String>? onOpenAgent,
  _AgentHubCatalogOrder? orderRecipes,
  PluginManagementBinding? plugins,
  SkillHubBinding? skills,
  String? presetId,
}) {
  final controller = AgentHubCatalogController(engine: engine);
  final feature = AgentHubRendererBindingFixture(controller);
  addTearDown(controller.dispose);
  addTearDown(feature.dispose);
  return (
    MaterialApp(
      locale: locale,
      supportedLocales: LicoStrings.supportedLocales,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      theme: presetId == null
          ? buildLicoTheme(platformBrightness: Brightness.dark)
          : buildLicoTheme(presetId: presetId),
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
            binding: feature.binding,
            plugins: plugins,
            skills: skills,
            openHomepage: openHomepage ?? (_) async {},
            onOpenAgent: onOpenAgent,
            orderEntries: orderRecipes ?? (entries) => entries,
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

List<String> _cardOrder(WidgetTester tester) {
  final positions = <String, Offset>{};
  for (final id in _ids) {
    final card = find.byKey(Key('agent-hub-card-$id'));
    if (card.evaluate().isNotEmpty) {
      positions[id] = tester.getTopLeft(card);
    }
  }
  final entries = positions.entries.toList()
    ..sort((a, b) {
      final byY = a.value.dy.compareTo(b.value.dy);
      return byY != 0 ? byY : a.value.dx.compareTo(b.value.dx);
    });
  return [for (final entry in entries) entry.key];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadBundledVisualFonts);
  test(
    'Agent Hub semantic projection keeps every supported agent once',
    () async {
      final controller = AgentHubCatalogController(engine: _FakeHubEngine());
      final feature = AgentHubRendererBindingFixture(controller);
      await controller.refresh();
      expect(
        feature.binding.projection.current.entries.map((entry) => entry.id),
        unorderedEquals(_ids),
      );
      await feature.dispose();
      controller.dispose();
    },
  );

  test('cached catalog remains visible and marks a failed refresh', () async {
    final cached = _snapshot(ownedIds: const {'codex'});
    final pending = Completer<AgentHubCatalogSnapshot>();
    final controller = AgentHubCatalogController(
      engine: _FakeHubEngine(seedCache: cached, catalogFuture: pending.future),
    );

    final refresh = controller.refresh();
    pending.completeError(StateError('catalog unavailable'));
    final result = await refresh;

    expect(result, same(cached));
    expect(controller.catalog, same(cached));
    expect(controller.failed, isTrue);
    expect(controller.busy, isFalse);
  });

  test(
    'Agent inspections publish independently and isolate failures',
    () async {
      final codex = Completer<AgentHubCatalogSnapshot>();
      final cursor = Completer<AgentHubCatalogSnapshot>();
      final owner = AgentHubCatalogController(
        engine: _FakeHubEngine(
          inspectDelays: {'codex': codex, 'cursor': cursor},
        ),
      );
      addTearDown(owner.dispose);
      final refresh = owner.refresh();
      await Future<void>.delayed(Duration.zero);
      expect(owner.isRecipeResolving('codex'), isTrue);
      expect(owner.isRecipeResolving('cursor'), isTrue);
      expect(owner.isRecipeResolving('opencode'), isFalse);
      cursor.complete(
        AgentHubCatalogSnapshot(
          recipes: _recipes().where((recipe) => recipe.id == 'cursor').toList(),
        ),
      );
      await Future<void>.delayed(Duration.zero);
      expect(owner.isRecipeResolving('cursor'), isFalse);
      await owner.refreshRecipe('cursor');
      expect(owner.isRecipeResolving('codex'), isTrue);
      expect(owner.isRecipeResolving('codex'), isTrue);
      expect(owner.catalog!.recipes, hasLength(_ids.length));
      codex.complete(const AgentHubCatalogSnapshot(recipes: [], ok: false));
      await refresh;
      expect(owner.isRecipeFailed('codex'), isTrue);
      expect(owner.isRecipeFailed('cursor'), isFalse);
      expect(owner.catalog!.recipes, hasLength(_ids.length));
    },
  );

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
      final header = tester.widget<Padding>(
        find.byKey(Key('agent-hub-header-$id')),
      );
      expect(
        header.padding,
        const EdgeInsets.fromLTRB(
          LicoContentSpacing.item,
          LicoContentSpacing.compact,
          LicoContentSpacing.item,
          0,
        ),
      );
      final cardRect = tester.getRect(find.byKey(Key('agent-hub-card-$id')));
      final nameRect = tester.getRect(find.byKey(Key('agent-hub-name-$id')));
      expect(
        cardRect.right - nameRect.right,
        greaterThanOrEqualTo(LicoContentSpacing.item - 0.5),
      );
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
      final inspection = Completer<void>();
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
        liveDelay: inspection,
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

      // The warehouse paint is followed by an independent Agent inspection.
      expect(engine.catalogRecipeIds, ['', 'codex']);
      expect(engine.liveRootRequests, 0);
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

      inspection.complete();
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

  testWidgets('failed Agent inspections preserve cards from the first paint', (
    tester,
  ) async {
    final warehouse = _snapshot();
    final batch = AgentHubCatalogSnapshot(
      recipes: warehouse.recipes
          .where((recipe) => recipe.id == 'codex')
          .toList(),
      scanGeneration: warehouse.scanGeneration,
      ok: true,
    );
    final engine = _FakeHubEngine(
      warehouseSnapshot: warehouse,
      liveSnapshot: batch,
    );
    await _pumpHub(tester, _harness(engine));

    expect(find.byKey(const Key('agent-hub-refresh')), findsOneWidget);
    for (final id in _ids) {
      expect(
        find.byKey(Key('agent-hub-card-$id')),
        findsOneWidget,
        reason: 'card $id must survive a partial batch',
      );
    }
    // Order follows the first catalog paint.
    expect(_cardOrder(tester), _ids);
    expect(tester.takeException(), isNull);
  });

  testWidgets('intro opens the agent detail and back returns to the catalog', (
    tester,
  ) async {
    await _pumpHub(tester, _harness(_FakeHubEngine()));

    await _openDetail(tester, 'codex');
    expect(find.byKey(const Key('agent-hub-detail-codex')), findsOneWidget);
    expect(find.byKey(const Key('agent-hub-card-codex')), findsNothing);
    expect(find.byKey(const Key('agent-hub-back')), findsOneWidget);
    expect(find.text('Agent Hub'), findsOneWidget);
    expect(find.text('Codex'), findsWidgets);
    expect(find.byKey(const Key('agent-hub-adaptation-codex')), findsNothing);
    expect(find.text('Official description'), findsNothing);
    expect(find.byKey(const Key('agent-hub-visit-codex')), findsOneWidget);
    expect(find.byKey(const Key('agent-hub-channel-codex')), findsNothing);
    expect(find.byKey(const Key('agent-hub-uninstall-codex')), findsNothing);
    expect(find.text('Install'), findsOneWidget);
    expect(find.text('Update'), findsNothing);
    expect(find.text('Chat'), findsNothing);
    expect(find.text('Open'), findsNothing);
    expect(find.text('Uninstall'), findsNothing);

    await tester.tap(find.byKey(const Key('agent-hub-back')));
    await tester.pump();
    expect(find.byKey(const Key('agent-hub-detail-codex')), findsNothing);
    expect(find.byKey(const Key('agent-hub-card-codex')), findsOneWidget);
    expect(find.byKey(const Key('agent-hub-back')), findsNothing);
    expect(find.text('Agent Hub'), findsOneWidget);
    expect(find.text('Uninstall'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'detail title bar refresh follows its active resource and retains page state',
    (tester) async {
      final engine = _FakeHubEngine();
      final skillFixture = SkillHubBindingFixture(skills: const []);
      final pluginEffects = SemanticEffectChannel<PluginManagementEffect>();
      final pluginIntents = <PluginManagementIntent>[];
      PluginManagementProjection pluginProjection(PresentationPhase phase) =>
          PluginManagementProjection(
            plugins: const [],
            workflows: const [],
            phase: phase,
          );
      final pluginSource = _MutableProjection(
        pluginProjection(PresentationPhase.ready),
      );
      addTearDown(skillFixture.dispose);
      addTearDown(pluginEffects.dispose);
      addTearDown(pluginSource.close);
      final plugins = PluginManagementBinding(
        projection: pluginSource,
        intents: SemanticIntentChannel<PluginManagementIntent>(
          pluginIntents.add,
        ),
        effects: pluginEffects,
      );
      await _pumpHub(
        tester,
        _harness(engine, plugins: plugins, skills: skillFixture.binding),
      );
      await _openDetail(tester, 'codex');
      pluginIntents.clear();
      skillFixture.receivedIntents.clear();
      int rootRequests() =>
          engine.catalogRecipeIds.where((id) => id.isEmpty).length;
      final beforeRefresh = rootRequests();
      final refresh = find.byKey(const Key('agent-hub-refresh'));
      final selector = find.byType(AgentHubDetailTabs);
      expect(
        find.descendant(
          of: find.byKey(const Key('agent-hub-top-bar')),
          matching: selector,
        ),
        findsOneWidget,
      );
      expect(
        tester.getRect(selector).right,
        closeTo(tester.getRect(refresh).left - 8, 0.1),
      );
      expect(
        tester.getRect(selector).center.dy,
        closeTo(tester.getRect(refresh).center.dy, 0.1),
      );
      expect(find.byKey(const Key('adapter-plugin-refresh')), findsNothing);
      expect(find.byKey(const Key('skill-hub-refresh')), findsNothing);
      final retainedSkillPage = tester.state(find.byType(SkillHubPanel));

      await tester.tap(refresh);
      await tester.pump();
      await tester.pump();
      expect(rootRequests(), beforeRefresh + 1);
      expect(pluginIntents, isEmpty);
      expect(skillFixture.receivedIntents, isEmpty);

      await tester.tap(find.byKey(const Key('agent-hub-detail-tab-1')));
      await tester.pump();
      await tester.tap(refresh);
      await tester.pump();
      expect(pluginIntents.whereType<RefreshPlugins>(), hasLength(1));
      expect(skillFixture.receivedIntents, isEmpty);
      expect(rootRequests(), beforeRefresh + 1);
      pluginSource.replace(pluginProjection(PresentationPhase.loading));
      await tester.pump();
      expect(tester.widget<LicoPaneRefreshButton>(refresh).refreshing, isTrue);
      expect(tester.widget<LicoPaneRefreshButton>(refresh).onPressed, isNull);

      await tester.tap(find.byKey(const Key('agent-hub-detail-tab-2')));
      await tester.pump();
      expect(tester.widget<LicoPaneRefreshButton>(refresh).refreshing, isFalse);
      await tester.tap(refresh);
      await tester.pump();
      expect(
        skillFixture.receivedIntents.whereType<RefreshSkillHub>(),
        hasLength(1),
      );
      expect(pluginIntents.whereType<RefreshPlugins>(), hasLength(1));
      expect(rootRequests(), beforeRefresh + 1);
      expect(tester.state(find.byType(SkillHubPanel)), same(retainedSkillPage));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'narrow large-text detail keeps its selector next to refresh and supports skills without plugins',
    (tester) async {
      final skillFixture = SkillHubBindingFixture(skills: const []);
      addTearDown(skillFixture.dispose);
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
      await _pumpHub(
        tester,
        _harness(
          _FakeHubEngine(),
          skills: skillFixture.binding,
          locale: const Locale('zh'),
          presetId: 'lico-soda-light',
        ),
      );
      await _openDetail(tester, 'codex');
      await tester.binding.setSurfaceSize(const Size(360, 640));
      await tester.pump();
      final header = tester.widget<LicoPaneTitleBar>(
        find.byKey(const Key('agent-hub-top-bar')),
      );
      expect(header.actionsOnSeparateLine, isTrue);
      final selector = tester.getRect(find.byType(AgentHubDetailTabs));
      final refresh = tester.getRect(
        find.byKey(const Key('agent-hub-refresh')),
      );
      expect(selector.right, closeTo(refresh.left - 8, 0.1));
      expect(selector.center.dy, closeTo(refresh.center.dy, 0.1));
      expect(find.text('概览'), findsOneWidget);
      expect(find.text('技能'), findsOneWidget);
      skillFixture.receivedIntents.clear();
      await tester.tap(find.byKey(const Key('agent-hub-detail-tab-1')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('agent-hub-refresh')));
      await tester.pump();
      expect(
        skillFixture.receivedIntents.whereType<RefreshSkillHub>(),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('detail keeps Agent skills usable while plugins are loading', (
    tester,
  ) async {
    final skillFixture = SkillHubBindingFixture(
      skills: [
        skillHubFixtureSkill(
          id: 'codex-review',
          name: 'Codex Review',
          isPublic: false,
          path: '/synthetic/skills/codex-review',
          agents: const [SkillAgentProjection(id: 'codex', label: 'Codex')],
        ),
        skillHubFixtureSkill(
          id: 'cursor-review',
          name: 'Cursor Review',
          isPublic: false,
          path: '/synthetic/skills/cursor-review',
          agents: const [SkillAgentProjection(id: 'cursor', label: 'Cursor')],
        ),
      ],
    );
    final effects = SemanticEffectChannel<PluginManagementEffect>();
    addTearDown(skillFixture.dispose);
    addTearDown(effects.dispose);
    final plugins = PluginManagementBinding(
      projection: _StaticProjection(
        PluginManagementProjection(
          plugins: const [],
          workflows: const [],
          phase: PresentationPhase.loading,
        ),
      ),
      intents: SemanticIntentChannel<PluginManagementIntent>((_) {}),
      effects: effects,
    );
    await _pumpHub(
      tester,
      _harness(
        _FakeHubEngine(),
        plugins: plugins,
        skills: skillFixture.binding,
      ),
    );
    await _openDetail(tester, 'codex');
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('goldens/agent_hub_official_detail.png'),
    );
    await tester.tap(find.byKey(const Key('agent-hub-detail-tab-1')));
    await tester.pump();
    expect(find.byKey(const Key('adapter-plugin-loading')), findsOneWidget);
    await tester.tap(find.byKey(const Key('agent-hub-detail-tab-2')));
    await tester.pump();
    expect(find.byKey(const Key('skill-card-codex-review')), findsOneWidget);
    expect(find.byKey(const Key('skill-card-cursor-review')), findsNothing);
    await tester.tap(find.byKey(const Key('skill-card-codex-review')));
    await tester.pump();
    expect(find.byKey(const Key('skill-detail-dialog')), findsOneWidget);
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

  testWidgets('detail shows the full official description and source link', (
    tester,
  ) async {
    await _pumpHub(tester, _harness(_FakeHubEngine()));
    await _openDetail(tester, 'cursor');
    final description = tester.widget<Text>(
      find.byKey(const Key('agent-hub-summary-cursor')),
    );
    expect(description.data, _summaries['cursor']);
    expect(description.maxLines, isNull);
    expect(find.byKey(const Key('agent-hub-visit-cursor')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('detail keeps the installed version visible', (tester) async {
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

    expect(find.byKey(const Key('agent-hub-channel-codex')), findsNothing);
    expect(
      tester
          .widget<Text>(find.byKey(const Key('agent-hub-version-codex')))
          .data,
      '0.147.0',
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
      _harness(
        _FakeHubEngine(),
        openHomepage: (_) async => throw StateError('open failed'),
      ),
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
    engine.liveRootRequests = 0;
    await tester.tap(find.byKey(const Key('agent-hub-refresh')));
    await tester.pump();
    await tester.pump();
    expect(engine.actions, isEmpty);
    // Each Agent receives a separate status lookup after the catalog paint.
    expect(engine.catalogRecipeIds.where((id) => id.isEmpty), hasLength(1));
    expect(engine.liveRootRequests, 0);
    expect(
      engine.catalogRecipeIds.where((id) => id.isNotEmpty),
      unorderedEquals(_ids),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'a refresh shuffles once and keeps order across independent results',
    (tester) async {
      final calls = <int>[];
      List<AgentHubEntryProjection> rotatingOrder(
        List<AgentHubEntryProjection> entries,
      ) {
        calls.add(entries.length);
        if (entries.isEmpty) {
          return entries;
        }
        if (calls.length.isEven) {
          return [entries.last, ...entries.sublist(0, entries.length - 1)];
        }
        return entries.reversed.toList();
      }

      final engine = _FakeHubEngine();
      await _pumpHub(tester, _harness(engine, orderRecipes: rotatingOrder));

      // Each Agent publishes independently without reordering the catalog.
      final settled = calls.length;
      expect(settled, greaterThan(0));
      final order = _cardOrder(tester);
      expect(
        engine.catalogRecipeIds.where((id) => id.isNotEmpty).length,
        _ids.length,
      );

      await tester.pump();
      await tester.pump();
      expect(calls.length, settled);
      expect(_cardOrder(tester), order);

      await tester.tap(find.byKey(const Key('agent-hub-refresh')));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      await tester.pump();

      // One more shuffle for the new refresh.
      expect(calls.length, settled + 1);
      expect(engine.liveRootRequests, 0);
      expect(
        engine.catalogRecipeIds.where((id) => id.isNotEmpty).length,
        _ids.length * 2,
      );
      final refreshed = _cardOrder(tester);
      await tester.pump();
      expect(_cardOrder(tester), refreshed);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Agent Hub panel joins plan/confirm/install/verify/rescan through the native port',
    (tester) async {
      final engine = _FakeHubEngine();
      final harness = _harness(engine);
      await _pumpHub(tester, harness);

      final controller = harness.$2;
      final plan = await controller.runLifecycle(
        AgentHubLifecycleAction.plan,
        recipeId: 'codex',
      );
      final confirm = await controller.runLifecycle(
        AgentHubLifecycleAction.confirm,
        recipeId: 'codex',
      );
      final install = await controller.runLifecycle(
        AgentHubLifecycleAction.install,
        recipeId: 'codex',
      );
      final verify = await controller.runLifecycle(
        AgentHubLifecycleAction.verify,
        recipeId: 'cursor',
      );
      final rescan = await controller.runLifecycle(
        AgentHubLifecycleAction.rescan,
        recipeId: 'opencode',
      );
      final update = await controller.runLifecycle(
        AgentHubLifecycleAction.update,
        recipeId: 'codex',
      );
      final uninstall = await controller.runLifecycle(
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
    final openAction = tester.getRect(
      find.byKey(const Key('agent-hub-open-codex')),
    );
    expect(openAction.height, greaterThanOrEqualTo(36));
    expect(find.byKey(const Key('agent-hub-uninstall-codex')), findsOneWidget);
    expect(find.byKey(const Key('agent-hub-install-codex')), findsNothing);
    expect(find.byKey(const Key('agent-hub-update-codex')), findsNothing);
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
      expect(find.byKey(const Key('agent-hub-channel-codex')), findsNothing);
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
    'cache paints immediately then locks actions until the live batch resolves',
    (tester) async {
      final pending = Completer<AgentHubCatalogSnapshot>();
      final liveGate = Completer<void>();
      final cached = _snapshot(ownedIds: const {'codex'});
      final engine = _FakeHubEngine(
        ownedIds: const {'codex'},
        seedCache: cached,
        catalogFuture: pending.future,
        liveDelay: liveGate,
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
      // every card behind the pending catalog and the batched live pass.
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

      // Still locked: the live batch has not landed yet.
      expect(
        find.byKey(const Key('agent-hub-card-loading-codex')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<InkWell>(find.byKey(const Key('agent-hub-open-codex')))
            .onTap,
        isNull,
      );

      // One batched resolution unlocks every card together.
      liveGate.complete();
      await tester.pump();
      await tester.pump();

      expect(
        find.byKey(const Key('agent-hub-card-loading-codex')),
        findsNothing,
      );
      expect(
        tester
            .widget<InkWell>(find.byKey(const Key('agent-hub-open-codex')))
            .onTap,
        isNotNull,
      );
      expect(find.byKey(const Key('agent-hub-uninstall-codex')), findsNothing);
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

  testWidgets('install picker installs directly and shows progress in place', (
    tester,
  ) async {
    final gate = Completer<void>();
    final engine = _FakeHubEngine(lifecycleGate: gate);
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
    await tester.tap(find.byKey(const Key('agent-hub-install-start')));
    await tester.pump();
    // No second confirmation: the same dialog morphs into its progress state.
    expect(
      find.byKey(const Key('agent-hub-install-confirm-dialog')),
      findsNothing,
    );
    expect(find.byKey(const Key('agent-hub-install-progress')), findsOneWidget);
    gate.complete();
    await tester.pumpAndSettle();
    expect(engine.actions, [
      AgentHubLifecycleAction.plan,
      AgentHubLifecycleAction.confirm,
      AgentHubLifecycleAction.install,
    ]);
    expect(engine.lastRecipeId, 'codex');
    expect(engine.lastChannelId, 'homebrew');
    expect(engine.lastVersion, 'latest');
    // The completed install closes the dialog on its own.
    expect(find.byKey(const Key('agent-hub-install-dialog')), findsNothing);
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
  Future<AgentHubCatalogSnapshot> catalog({
    String recipeId = '',
    bool live = false,
  }) async {
    return const AgentHubCatalogSnapshot(recipes: [], ok: false);
  }
}

final class _ThrowingCatalogEngine
    with _StubHubCatalog
    implements AgentHubEnginePort {
  const _ThrowingCatalogEngine();

  @override
  Future<AgentHubCatalogSnapshot> catalog({
    String recipeId = '',
    bool live = false,
  }) async {
    throw StateError('native catalog failed');
  }
}

int _summaryLineCount(List<TextBox> boxes) {
  final tops = boxes.map((box) => box.top).toList()..sort();
  var count = 0;
  var last = -100.0;
  for (final top in tops) {
    if (top - last > 12) {
      count++;
      last = top;
    }
  }
  return count;
}

final class _StaticProjection<P> implements ProjectionSource<P> {
  const _StaticProjection(this.current);
  @override
  final P current;
  @override
  Stream<ProjectionUpdate<P>> get changes => const Stream.empty();
}

final class _MutableProjection<P> implements ProjectionSource<P> {
  _MutableProjection(this.current);
  @override
  P current;
  final _updates = StreamController<ProjectionUpdate<P>>.broadcast(sync: true);
  @override
  Stream<ProjectionUpdate<P>> get changes => _updates.stream;
  void replace(P next) {
    current = next;
    _updates.add(ProjectionUpdate(next));
  }

  Future<void> close() => _updates.close();
}
