import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/presentation/search/search_projection.dart';

final class RankedSearchCatalog {
  const RankedSearchCatalog({
    this.primary = const [],
    this.features = const [],
    this.skills = const [],
    this.conversations = const [],
  });

  final List<SearchCatalogEntry> primary;
  final List<SearchCatalogEntry> features;
  final List<Map<String, dynamic>> skills;
  final List<SearchResultProjection> conversations;

  int get resultCount =>
      primary.length + features.length + skills.length + conversations.length;
}

int scorePrefixSearchFields(String query, List<String> fields) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return 0;
  var best = 0;
  for (final field in fields) {
    final value = field.toLowerCase();
    if (value.startsWith(needle)) return 2;
    if (best == 0 && value.contains(needle)) best = 1;
  }
  return best;
}

int scoreSkillHubSearchEntry(Map<String, dynamic> skill, String query) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) return 0;
  final name = scorePrefixSearchFields(needle, [
    (skill['title'] ?? '').toString(),
    (skill['skillId'] ?? '').toString(),
  ]);
  if (name > 0) return name + 2;
  return scorePrefixSearchFields(needle, [
    (skill['description'] ?? '').toString(),
    (skill['content'] ?? '').toString(),
  ]);
}

List<SearchCatalogEntry> _matchingFeatures(
  List<SearchCatalogEntry> entries,
  String query,
) => [
  for (final entry in entries)
    if (entry.matchScore(query) > 0) entry,
]..sort((a, b) => b.matchScore(query).compareTo(a.matchScore(query)));

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

RankedSearchCatalog rankSearchCatalog({
  required ClientSection destination,
  required String query,
  required List<SearchCatalogEntry> features,
  required List<SearchCatalogEntry> settingsFeatures,
  required List<SearchCatalogEntry> agentFeatures,
  required List<SearchCatalogEntry> pluginFeatures,
  required List<Map<String, dynamic>> skills,
  required double Function(Map<String, dynamic> skill, String query) skillScore,
  required List<SearchResultProjection> conversations,
}) {
  final needle = query.trim();
  if (needle.isEmpty) return const RankedSearchCatalog();

  final featureHits = _matchingFeatures(features, needle);
  final settingsHits = _matchingFeatures(settingsFeatures, needle);
  final agentHits = _matchingFeatures(agentFeatures, needle);
  final pluginHits = _matchingFeatures(pluginFeatures, needle);

  switch (destination) {
    case ClientSection.settings:
      return RankedSearchCatalog(primary: settingsHits);
    case ClientSection.skillHub:
      return RankedSearchCatalog(
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
      return RankedSearchCatalog(
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
      return RankedSearchCatalog(
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
      return RankedSearchCatalog(
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
