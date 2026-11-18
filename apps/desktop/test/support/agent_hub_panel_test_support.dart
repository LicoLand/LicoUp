import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod/misc.dart' show Override;
import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/application/features/agent_hub/agent_hub_catalog_controller.dart';
import 'package:licoup/src/contracts/agent_hub.dart';
import 'package:licoup/src/frontend/features/agent_hub/ui/agent_hub_panel.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/agent_hub/agent_hub_projection.dart';
import 'package:licoup/src/presentation/plugin_management/plugin_management_binding.dart';
import 'package:licoup/src/presentation/skill_hub/skill_hub_binding.dart';

import '../fixtures/agent_hub_renderer_binding_fixture.dart';
import '../fixtures/plugin_management_presentation_fixture.dart';
import '../fixtures/skill_hub_presentation_fixture.dart';

const agentHubTestIds = [
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

const agentHubTestSummaries = {
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

const agentHubTestHomepages = {
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

List<AgentHubRecipe> agentHubTestRecipes({
  Set<String> presentIds = const {},
  Set<String> externalIds = const {},
  Set<String> externalProtectedIds = const {},
  Set<String> ownedIds = const {},
  Set<String> failedIds = const {},
  Set<String> updateAvailableIds = const {},
  Map<String, String> installedVersions = const {},
  Map<String, String> latestVersions = const {},
  Map<String, List<String>> installKinds = const {},
  Map<String, String> displayNames = const {},
}) {
  return [
    for (final id in agentHubTestIds)
      AgentHubRecipe(
        id: id,
        displayName: displayNames[id] ?? _title(id),
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
        summary: agentHubTestSummaries[id]!,
        homepage: agentHubTestHomepages[id]!,
        installedVersion: installedVersions[id] ?? '',
        latestVersion: latestVersions[id] ?? '',
        updateAvailable: updateAvailableIds.contains(id),
        version: installedVersions[id] ?? '',
        installKinds: installKinds[id] ?? const [],
        installChannels: _channels(id),
      ),
  ];
}

AgentHubCatalogSnapshot agentHubTestSnapshot({
  Set<String> presentIds = const {},
  Set<String> externalIds = const {},
  Set<String> externalProtectedIds = const {},
  Set<String> ownedIds = const {},
  Set<String> failedIds = const {},
  Set<String> updateAvailableIds = const {},
  Map<String, String> installedVersions = const {},
  Map<String, String> latestVersions = const {},
  Map<String, List<String>> installKinds = const {},
  Map<String, String> displayNames = const {},
}) {
  return AgentHubCatalogSnapshot(
    recipes: agentHubTestRecipes(
      presentIds: presentIds,
      externalIds: externalIds,
      externalProtectedIds: externalProtectedIds,
      ownedIds: ownedIds,
      failedIds: failedIds,
      updateAvailableIds: updateAvailableIds,
      installedVersions: installedVersions,
      latestVersions: latestVersions,
      installKinds: installKinds,
      displayNames: displayNames,
    ),
  );
}

final class FakeAgentHubEngine implements AgentHubEnginePort {
  FakeAgentHubEngine({
    this.presentIds = const {},
    this.externalIds = const {},
    this.externalProtectedIds = const {},
    this.ownedIds = const {},
    this.failedIds = const {},
    this.updateAvailableIds = const {},
    this.installedVersions = const {},
    this.latestVersions = const {},
    this.installKinds = const {},
    this.displayNames = const {},
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
  final Map<String, List<String>> installKinds;
  final Map<String, String> displayNames;
  final AgentHubCatalogSnapshot? seedCache;
  final AgentHubCatalogSnapshot? warehouseSnapshot;
  final AgentHubCatalogSnapshot? liveSnapshot;
  final Future<AgentHubCatalogSnapshot>? catalogFuture;
  final Completer<void>? lifecycleGate;
  final Map<String, Completer<AgentHubCatalogSnapshot>> inspectDelays;
  final Completer<void>? liveDelay;
  final List<AgentHubLifecycleAction> actions = [];
  final List<String> catalogRecipeIds = [];
  int liveRootRequests = 0;
  String? lastRecipeId;
  String? lastChannelId;
  String? lastVersion;
  AgentHubCatalogSnapshot? _cache;

  AgentHubCatalogSnapshot get _liveSnapshot => agentHubTestSnapshot(
    presentIds: presentIds,
    externalIds: externalIds,
    externalProtectedIds: externalProtectedIds,
    ownedIds: ownedIds,
    failedIds: failedIds,
    updateAvailableIds: updateAvailableIds,
    installedVersions: installedVersions,
    latestVersions: latestVersions,
    installKinds: installKinds,
    displayNames: displayNames,
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

typedef AgentHubHarness = (Widget, AgentHubCatalogController);
typedef AgentHubCatalogOrder =
    List<AgentHubEntryProjection> Function(
      List<AgentHubEntryProjection> entries, [
      int? seed,
    ]);

AgentHubHarness buildAgentHubHarness(
  AgentHubEnginePort engine, {
  Locale locale = const Locale('en'),
  AgentHubExternalOpener? openHomepage,
  ValueChanged<String>? onOpenAgent,
  AgentHubCatalogOrder? orderRecipes,
  PluginManagementBinding? plugins,
  SkillHubBinding? skills,
  PluginManagementPresentationFixture? pluginPresentation,
  SkillHubPresentationFixture? skillPresentation,
  String? presetId,
  bool reduceMotion = true,
}) {
  final controller = AgentHubCatalogController(engine: engine);
  final feature = AgentHubRendererBindingFixture(controller);
  addTearDown(controller.dispose);
  addTearDown(feature.dispose);
  final overrides = <Override>[
    ...?pluginPresentation?.overrides,
    ...?skillPresentation?.overrides,
  ];
  final app = MaterialApp(
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
        data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
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
          orderEntries: orderRecipes ?? (entries, [seed]) => entries,
        ),
      ),
    ),
  );
  return (
    overrides.isEmpty ? app : ProviderScope(overrides: overrides, child: app),
    controller,
  );
}

Future<void> openAgentHubDetail(WidgetTester tester, String id) async {
  await tester.tap(find.byKey(Key('agent-hub-intro-$id')));
  await tester.pump();
}

Future<void> pumpAgentHubPanel(
  WidgetTester tester,
  AgentHubHarness harness,
) async {
  final (app, controller) = harness;
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

final class StaticAgentHubProjection<P> implements ProjectionSource<P> {
  const StaticAgentHubProjection(this.current);
  @override
  final P current;
  @override
  Stream<ProjectionUpdate<P>> get changes => const Stream.empty();
}
