import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/features/agents/ui/global_search_features.dart';

final class AgentConversationSearchDocument {
  const AgentConversationSearchDocument({
    required this.agentId,
    required this.sessionId,
    required this.title,
  });

  final String agentId;
  final String sessionId;
  final String title;
}

final class AgentConversationSearchHit {
  const AgentConversationSearchHit({
    required this.document,
    required this.score,
    required this.snippet,
    required this.titleMatched,
  });

  final AgentConversationSearchDocument document;
  final double score;
  final String snippet;
  final bool titleMatched;
}

/// Ranked global-search groups for one destination.
///
/// Conversation ranking is supplied already-scored by the existing index and
/// is never reordered here. Settings shows only settings-function hits.
final class DestinationSearchHits {
  const DestinationSearchHits({
    this.primary = const [],
    this.features = const [],
    this.skills = const [],
    this.conversations = const [],
  });

  /// Destination-priority entries (agents on Agent Hub, plugins on Plugins,
  /// settings functions on Settings). Empty on Chat and Skill Hub.
  final List<GlobalSearchFeatureEntry> primary;
  final List<GlobalSearchFeatureEntry> features;
  final List<Map<String, dynamic>> skills;
  final List<AgentConversationSearchHit> conversations;

  int get resultCount =>
      primary.length + features.length + skills.length + conversations.length;
}

/// Prefix-first field scoring shared by Agent Hub / plugin / settings
/// destination entries. Name-style fields should be passed first.
int scorePrefixSearchFields(String query, List<String> fields) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) {
    return 0;
  }
  var best = 0;
  for (final field in fields) {
    final value = field.toLowerCase();
    if (value.startsWith(needle)) {
      return 2;
    }
    if (best == 0 && value.contains(needle)) {
      best = 1;
    }
  }
  return best;
}

List<GlobalSearchFeatureEntry> _matchingFeatures(
  List<GlobalSearchFeatureEntry> entries,
  String query,
) {
  return [
    for (final entry in entries)
      if (entry.matchScore(query) > 0) entry,
  ]..sort((a, b) => b.matchScore(query).compareTo(a.matchScore(query)));
}

List<Map<String, dynamic>> _matchingSkills({
  required List<Map<String, dynamic>> skills,
  required String query,
  required double Function(Map<String, dynamic> skill, String query) score,
  required int limit,
}) {
  final ranked = <({double score, int index, Map<String, dynamic> skill})>[];
  for (var index = 0; index < skills.length; index++) {
    final value = score(skills[index], query);
    if (value > 0) {
      ranked.add((score: value, index: index, skill: skills[index]));
    }
  }
  ranked.sort((left, right) {
    final byScore = right.score.compareTo(left.score);
    return byScore != 0 ? byScore : left.index.compareTo(right.index);
  });
  return [for (final item in ranked.take(limit)) item.skill];
}

/// Binds one query to the visible destination. Chat/Agents keeps the existing
/// feature → skill → conversation order. Settings returns only settings
/// functions (no filler). Feature panes put the current pane first, then the
/// remaining groups.
DestinationSearchHits rankDestinationSearch({
  required ClientSection destination,
  required String query,
  required List<GlobalSearchFeatureEntry> features,
  required List<GlobalSearchFeatureEntry> settingsFeatures,
  required List<GlobalSearchFeatureEntry> agentFeatures,
  required List<GlobalSearchFeatureEntry> pluginFeatures,
  required List<Map<String, dynamic>> skills,
  required double Function(Map<String, dynamic> skill, String query) skillScore,
  required List<AgentConversationSearchHit> conversations,
}) {
  final needle = query.trim();
  if (needle.isEmpty) {
    return const DestinationSearchHits();
  }

  final featureHits = _matchingFeatures(features, needle);
  final settingsHits = _matchingFeatures(settingsFeatures, needle);
  final agentHits = _matchingFeatures(agentFeatures, needle);
  final pluginHits = _matchingFeatures(pluginFeatures, needle);

  switch (destination) {
    case ClientSection.settings:
      return DestinationSearchHits(primary: settingsHits);
    case ClientSection.skillHub:
      return DestinationSearchHits(
        skills: _matchingSkills(
          skills: skills,
          query: needle,
          score: skillScore,
          limit: 12,
        ),
        features: featureHits,
        conversations: conversations,
      );
    case ClientSection.agentHub:
      return DestinationSearchHits(
        primary: agentHits,
        features: featureHits,
        skills: _matchingSkills(
          skills: skills,
          query: needle,
          score: skillScore,
          limit: 6,
        ),
        conversations: conversations,
      );
    case ClientSection.pluginManagement:
      return DestinationSearchHits(
        primary: pluginHits,
        features: featureHits,
        skills: _matchingSkills(
          skills: skills,
          query: needle,
          score: skillScore,
          limit: 6,
        ),
        conversations: conversations,
      );
    case ClientSection.agents:
    case ClientSection.monitoring:
    case ClientSection.mobileRelay:
    case ClientSection.models:
      return DestinationSearchHits(
        features: featureHits,
        skills: _matchingSkills(
          skills: skills,
          query: needle,
          score: skillScore,
          limit: 6,
        ),
        conversations: conversations,
      );
  }
}
