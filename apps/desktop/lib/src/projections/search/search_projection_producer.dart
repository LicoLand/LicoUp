import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/features/agents/conversation/agent_conversation_search_index.dart';
import 'package:licoup/src/application/state/application_signal.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/agent_product_identity.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';
import 'package:licoup/src/presentation/search/search_projection.dart';
import 'package:licoup/src/projections/close_broadcast_controller.dart';
import 'package:licoup/src/projections/search/search_ranking.dart';

final class SearchCatalogEntries {
  SearchCatalogEntries({
    required Iterable<SearchCatalogEntry> features,
    required Iterable<SearchCatalogEntry> settingsFeatures,
    required Iterable<SearchCatalogEntry> agentFeatures,
    required Iterable<SearchCatalogEntry> pluginFeatures,
    required this.featuresGroupLabel,
    required this.skillsGroupLabel,
    required this.settingsGroupLabel,
    required this.agentHubGroupLabel,
    required this.pluginGroupLabel,
  }) : features = List<SearchCatalogEntry>.unmodifiable(features),
       settingsFeatures = List<SearchCatalogEntry>.unmodifiable(
         settingsFeatures,
       ),
       agentFeatures = List<SearchCatalogEntry>.unmodifiable(agentFeatures),
       pluginFeatures = List<SearchCatalogEntry>.unmodifiable(pluginFeatures);

  final List<SearchCatalogEntry> features;
  final List<SearchCatalogEntry> settingsFeatures;
  final List<SearchCatalogEntry> agentFeatures;
  final List<SearchCatalogEntry> pluginFeatures;
  final String featuresGroupLabel;
  final String skillsGroupLabel;
  final String settingsGroupLabel;
  final String agentHubGroupLabel;
  final String pluginGroupLabel;
}

typedef SearchCatalogReader = SearchCatalogEntries Function(String localeCode);

final class SearchProjectionProducer
    implements ProjectionSource<SearchProjection> {
  SearchProjectionProducer(
    ClientController controller, {
    required SearchCatalogReader readCatalog,
  }) : _readCatalog = readCatalog,
       _controller = controller,
       _current = SearchProjection(
         query: '',
         results: const <SearchResultProjection>[],
         open: false,
         phase: PresentationPhase.idle,
       ) {
    _subscriptions = <StreamSubscription<ApplicationChange>>[
      controller.targetController.changes.listen(_handleApplicationChange),
      controller.conversationPresentationSignals.structureChanges.listen(
        _handleApplicationChange,
      ),
      controller.clientConversationController.changes.listen(
        _handleApplicationChange,
      ),
      controller.skillHubController.changes.listen(_handleApplicationChange),
    ];
  }

  final ClientController _controller;
  final SearchCatalogReader _readCatalog;
  final AgentConversationSearchIndex _index = AgentConversationSearchIndex();
  late final List<StreamSubscription<ApplicationChange>> _subscriptions;
  final StreamController<ProjectionUpdate<SearchProjection>> _changes =
      StreamController<ProjectionUpdate<SearchProjection>>.broadcast(
        sync: true,
      );
  SearchProjection _current;
  bool _closed = false;
  String _localeCode = 'en';

  @override
  SearchProjection get current => _current;

  @override
  Stream<ProjectionUpdate<SearchProjection>> get changes => _changes.stream;

  void open({required String localeCode, TraceContext? trace}) {
    _localeCode = localeCode;
    _replace(query: '', open: true, trace: trace, force: true);
  }

  void dismiss({TraceContext? trace}) => _replace(open: false, trace: trace);

  void updateQuery(String query, {TraceContext? trace}) =>
      _replace(query: query, trace: trace);

  void _handleApplicationChange(ApplicationChange change) {
    _replace(
      trace: change.cause?.traceId == null
          ? null
          : TraceContext(traceId: change.cause!.traceId),
      force: true,
    );
  }

  void _replace({
    String? query,
    bool? open,
    TraceContext? trace,
    bool force = false,
  }) {
    if (_closed) return;
    final nextQuery = query ?? _current.query;
    final nextOpen = open ?? _current.open;
    if (!force && nextQuery == _current.query && nextOpen == _current.open) {
      return;
    }
    final next = _read(nextQuery, nextOpen);
    if (next == _current) return;
    _current = next;
    _changes.add(ProjectionUpdate<SearchProjection>(next, trace: trace));
  }

  SearchProjection _read(String query, bool open) {
    final trimmed = query.trim();
    final catalog = _readCatalog(_localeCode);
    final documents = <AgentConversationSearchDocument>[];
    for (final entry in _controller.conversationSessionsByAgent.entries) {
      for (final session in entry.value) {
        documents.add(
          AgentConversationSearchDocument(
            agentId: entry.key,
            sessionId: session.id,
            title: session.title,
            content: _sessionContent(session),
            updatedAt: DateTime.tryParse(session.updatedAt),
          ),
        );
      }
    }
    _index.rebuild(documents);
    final conversationHits = [
      for (final hit in _index.search(trimmed, limit: 50))
        SearchResultProjection(
          id: 'conversation:${hit.document.agentId}\u0000${hit.document.sessionId}',
          title: hit.document.title.trim().isEmpty
              ? hit.document.sessionId
              : hit.document.title,
          subtitle: hit.snippet,
          destination: ClientSection.agents,
          resultKind: 'conversation',
          groupId: hit.document.agentId,
          emphasized: hit.titleMatched,
        ),
    ];
    final destination = _controller.currentSection;
    final ranked = rankSearchCatalog(
      destination: destination,
      query: trimmed,
      features: catalog.features,
      settingsFeatures: catalog.settingsFeatures,
      agentFeatures: catalog.agentFeatures,
      pluginFeatures: catalog.pluginFeatures,
      skills: _controller.skillHubController.skills,
      skillScore: destination == ClientSection.skillHub
          ? (skill, needle) =>
                scoreSkillHubSearchEntry(skill, needle).toDouble()
          : _scoreSkillSearchEntry,
      conversations: conversationHits,
    );
    final results = _flattenResults(ranked, destination, catalog);
    return SearchProjection(
      query: query,
      results: results,
      open: open,
      phase: trimmed.isEmpty ? PresentationPhase.idle : PresentationPhase.ready,
    );
  }

  List<SearchResultProjection> _flattenResults(
    RankedSearchCatalog ranked,
    ClientSection destination,
    SearchCatalogEntries catalog,
  ) {
    final results = <SearchResultProjection>[];

    void addFeatures(
      List<SearchCatalogEntry> entries,
      String groupId,
      String groupLabel,
    ) {
      for (final entry in entries) {
        results.add(
          SearchResultProjection(
            id: 'feature:${entry.id}',
            title: entry.label,
            subtitle: '',
            destination: destination,
            resultKind: 'feature',
            groupId: groupId,
            groupLabel: groupLabel,
          ),
        );
      }
    }

    void addSkills() {
      for (final skill in ranked.skills) {
        final skillId = (skill['skillId'] ?? skill['id'] ?? '').toString();
        final title = (skill['title'] ?? skillId).toString();
        results.add(
          SearchResultProjection(
            id: 'skill:$skillId',
            title: title.trim().isEmpty ? skillId : title,
            subtitle: (skill['description'] ?? '').toString(),
            destination: ClientSection.skillHub,
            resultKind: 'skill',
            groupId: 'skills',
            groupLabel: catalog.skillsGroupLabel,
          ),
        );
      }
    }

    final skillsFirst = destination == ClientSection.skillHub;
    if (skillsFirst) addSkills();
    addFeatures(ranked.primary, 'primary', switch (destination) {
      ClientSection.settings => catalog.settingsGroupLabel,
      ClientSection.agentHub => catalog.agentHubGroupLabel,
      ClientSection.pluginManagement => catalog.pluginGroupLabel,
      _ => catalog.featuresGroupLabel,
    });
    addFeatures(ranked.features, 'features', catalog.featuresGroupLabel);
    if (!skillsFirst) addSkills();

    for (final hit in ranked.conversations) {
      final target = _controller.targetController.targets
          .where(
            (candidate) =>
                candidate.id == hit.groupId || candidate.target == hit.groupId,
          )
          .firstOrNull;
      final groupLabel = target == null
          ? hit.groupId
          : agentProductDisplayName(target.target) ??
                agentProductLabel(
                  target.label.trim().isEmpty ? target.target : target.label,
                );
      results.add(
        SearchResultProjection(
          id: hit.id,
          title: hit.title,
          subtitle: hit.subtitle,
          destination: hit.destination,
          resultKind: hit.resultKind,
          groupId: 'agent:${hit.groupId}',
          groupLabel: groupLabel,
          emphasized: hit.emphasized,
        ),
      );
    }
    return results;
  }

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    for (final subscription in _subscriptions.reversed) {
      await subscription.cancel();
    }
    await closeBroadcastController(_changes);
  }
}

String _sessionContent(AgentConversationSession session) {
  final messages = session.semantic?.thread ?? session.messages;
  return <String>[
    session.preview,
    for (final message in messages) message.text,
  ].where((text) => text.trim().isNotEmpty).join('\n');
}

double _scoreSkillSearchEntry(Map<String, dynamic> skill, String query) {
  final normalized = query.trim().toLowerCase();
  if (normalized.isEmpty) return 0;
  final title = (skill['title'] ?? '').toString().toLowerCase();
  final skillId = (skill['skillId'] ?? '').toString().toLowerCase();
  final author = (skill['author'] ?? '').toString().toLowerCase();
  final description = (skill['description'] ?? '').toString().toLowerCase();
  var score = 0.0;
  if (title.contains(normalized)) score += 6;
  if (skillId.contains(normalized)) score += 5;
  if (author.contains(normalized)) score += 2;
  for (final term
      in normalized.split(RegExp(r'\s+')).where((term) => term.isNotEmpty)) {
    if (title.contains(term)) {
      score += 2;
    } else if (skillId.contains(term)) {
      score += 1.5;
    } else if (description.contains(term)) {
      score += 1;
    }
  }
  return score;
}
