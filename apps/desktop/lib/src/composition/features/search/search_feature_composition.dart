import 'dart:async';
import 'dart:ui' show Locale;

import 'package:flutter/material.dart' show Icons;
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/composition/renderer_intent_trace.dart';
import 'package:licoup/src/presentation/agents/agent_product_identity.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/features/agents/ui/global_search_features.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/presentation/search/search_binding.dart';
import 'package:licoup/src/presentation/search/search_effect.dart';
import 'package:licoup/src/presentation/search/search_intent.dart';
import 'package:licoup/src/presentation/search/search_projection.dart';
import 'package:licoup/src/projections/close_broadcast_controller.dart';
import 'package:licoup/src/projections/search/search_projection_producer.dart';

final class SearchFeatureComposition {
  SearchFeatureComposition(
    ClientController controller, {
    RendererIntentTraceFactory? beginRendererIntent,
    List<GlobalSearchFeatureEntry>? features,
    List<GlobalSearchFeatureEntry>? settingsFeatures,
    List<GlobalSearchFeatureEntry>? agentFeatures,
    List<GlobalSearchFeatureEntry>? pluginFeatures,
  }) {
    _catalog = _SearchCatalog(
      controller,
      features: features,
      settingsFeatures: settingsFeatures,
      agentFeatures: agentFeatures,
      pluginFeatures: pluginFeatures,
    );
    _projection = SearchProjectionProducer(
      controller,
      readCatalog: _catalog.read,
    );
    _effects = _SearchEffects();
    _intents = _SearchIntents(
      controller,
      _catalog,
      beginRendererIntent: beginRendererIntent,
    );
    _intents
      ..projection = _projection
      ..effects = _effects;
    binding = SearchBinding(
      projection: _projection,
      intents: _intents,
      effects: _effects,
    );
  }

  late final _SearchCatalog _catalog;
  late final SearchProjectionProducer _projection;
  late final _SearchEffects _effects;
  late final _SearchIntents _intents;
  late final SearchBinding binding;
  Future<void>? _disposal;

  Future<void> close() => _disposal ??= _close();

  Future<void> _close() async {
    await _projection.close();
    await _effects.close();
  }
}

final class _SearchEffects implements EffectSource<SearchEffect> {
  final StreamController<SearchEffect> _controller =
      StreamController<SearchEffect>.broadcast(sync: true);

  @override
  Stream<SearchEffect> get effects => _controller.stream;

  void add(SearchEffect effect) => _controller.add(effect);

  Future<void> close() => closeBroadcastController(_controller);
}

final class _SearchIntents implements IntentSink<SearchIntent> {
  _SearchIntents(
    this._controller,
    this._catalog, {
    RendererIntentTraceFactory? beginRendererIntent,
  }) : _beginRendererIntent = beginRendererIntent;

  final ClientController _controller;
  final _SearchCatalog _catalog;
  final RendererIntentTraceFactory? _beginRendererIntent;
  late SearchProjectionProducer projection;
  late _SearchEffects effects;

  @override
  void send(SearchIntent intent) {
    final trace = resolveRendererIntentTrace(
      intent.trace,
      _beginRendererIntent,
    );
    switch (intent) {
      case OpenSearch(:final localeCode):
        projection.open(localeCode: localeCode, trace: trace);
        for (final target in _controller.scannedTargets) {
          if (!target.isConversationAgent) continue;
          final sessions = _controller.conversationSessionsByAgent[target.id];
          if (sessions == null || sessions.isEmpty) {
            unawaited(_controller.refreshConversationSessions(target.id));
          }
        }
      case UpdateSearchQuery(:final query):
        projection.updateQuery(query, trace: trace);
      case DismissSearch():
        projection.dismiss(trace: trace);
      case SelectSearchResult(:final resultId):
        _select(resultId, trace);
    }
  }

  void _select(String resultId, TraceContext? trace) {
    final separator = resultId.indexOf(':');
    if (separator <= 0 || separator == resultId.length - 1) {
      effects.add(
        SearchSelectionRejected(
          resultId,
          'search_result_invalid',
          trace: trace,
        ),
      );
      return;
    }
    final kind = resultId.substring(0, separator);
    final value = resultId.substring(separator + 1);
    switch (kind) {
      case 'agent':
        _controller.selectSection(ClientSection.agents);
        unawaited(_controller.selectConversationAgent(value));
      case 'conversation':
        final identity = value.split('\u0000');
        if (identity.length != 2) {
          effects.add(
            SearchSelectionRejected(
              resultId,
              'search_result_invalid',
              trace: trace,
            ),
          );
          return;
        }
        unawaited(() async {
          await _controller.selectConversationAgent(identity.first);
          _controller.selectConversationSession(identity.last);
        }());
      case 'skill':
        _controller.selectSection(ClientSection.skillHub);
      case 'feature':
        final action = _catalog.action(value);
        if (action == null) {
          effects.add(
            SearchSelectionRejected(
              resultId,
              'search_result_invalid',
              trace: trace,
            ),
          );
          return;
        }
        unawaited(action());
      default:
        effects.add(
          SearchSelectionRejected(
            resultId,
            'search_result_unsupported',
            trace: trace,
          ),
        );
    }
    projection.dismiss(trace: trace);
  }
}

final class _SearchCatalog {
  _SearchCatalog(
    this._controller, {
    this.features,
    this.settingsFeatures,
    this.agentFeatures,
    this.pluginFeatures,
  });

  final ClientController _controller;
  final List<GlobalSearchFeatureEntry>? features;
  final List<GlobalSearchFeatureEntry>? settingsFeatures;
  final List<GlobalSearchFeatureEntry>? agentFeatures;
  final List<GlobalSearchFeatureEntry>? pluginFeatures;
  Map<String, Future<void> Function()> _actions = const {};

  SearchCatalogEntries read(String localeCode) {
    final strings = LicoStrings.forLocale(Locale(localeCode));
    final resolvedFeatures =
        features ??
        buildGlobalSearchFeatures(
          strings: strings,
          onSelectSection: _controller.selectSection,
          onNewConversation: _controller.startNewConversationSession,
        );
    final resolvedSettings =
        settingsFeatures ??
        buildSettingsSearchFeatures(
          strings: strings,
          onOpenSettings: () =>
              _controller.selectSection(ClientSection.settings),
        );
    final resolvedAgents =
        agentFeatures ??
        buildAgentSearchFeatures(
          targets: _controller.scannedTargets,
          onOpenAgentHub: () =>
              _controller.selectSection(ClientSection.agentHub),
        );
    final resolvedPlugins = pluginFeatures ?? _pluginEntries();
    final allEntries = <GlobalSearchFeatureEntry>[
      ...resolvedFeatures,
      ...resolvedSettings,
      ...resolvedAgents,
      ...resolvedPlugins,
    ];
    _actions = {for (final entry in allEntries) entry.id: entry.run};
    return SearchCatalogEntries(
      features: resolvedFeatures.map(_semantic),
      settingsFeatures: resolvedSettings.map(_semantic),
      agentFeatures: resolvedAgents.map(_semantic),
      pluginFeatures: resolvedPlugins.map(_semantic),
      featuresGroupLabel: strings.searchFeaturesGroup,
      skillsGroupLabel: strings.skillHub,
      settingsGroupLabel: strings.settings,
      agentHubGroupLabel: strings.agentHub,
      pluginGroupLabel: strings.pluginManagement,
    );
  }

  Future<void> Function()? action(String id) => _actions[id];

  SearchCatalogEntry _semantic(GlobalSearchFeatureEntry entry) =>
      SearchCatalogEntry(
        id: entry.id,
        label: entry.label,
        keywords: entry.keywords,
      );

  List<GlobalSearchFeatureEntry> _pluginEntries() => [
    for (final adapter in _controller.adapterPluginController.adapters)
      GlobalSearchFeatureEntry(
        id: 'plugin-adapter-${adapter.agentId}',
        label: agentProductLabel(adapter.label),
        keywords: [
          adapter.agentId,
          adapter.label,
          'plugin',
          'adapter',
          '插件',
          '适配器',
        ],
        icon: Icons.extension_outlined,
        run: () async =>
            _controller.selectSection(ClientSection.pluginManagement),
      ),
  ];
}
