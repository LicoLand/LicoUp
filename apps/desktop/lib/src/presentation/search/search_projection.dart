import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

/// One immutable search-catalog value. Flutter icons and executable callbacks
/// remain composition-local and are never projected into renderer state.
final class SearchCatalogEntry {
  SearchCatalogEntry({
    required this.id,
    required this.label,
    required Iterable<String> keywords,
  }) : keywords = immutablePresentationList(keywords);

  final String id;
  final String label;
  final List<String> keywords;

  double matchScore(String query) {
    final normalized = query.trim().toLowerCase();
    if (normalized.isEmpty) return 0;
    final lowerLabel = label.toLowerCase();
    var score = 0.0;
    if (lowerLabel.contains(normalized)) score += 6;
    if (keywords.any((keyword) => keyword.toLowerCase().contains(normalized))) {
      score += 3;
    }
    for (final term
        in normalized.split(RegExp(r'\s+')).where((term) => term.isNotEmpty)) {
      if (lowerLabel.contains(term)) {
        score += 2;
      } else if (keywords.any(
        (keyword) => keyword.toLowerCase().contains(term),
      )) {
        score += 1;
      }
    }
    return score;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SearchCatalogEntry &&
          other.id == id &&
          other.label == label &&
          samePresentationList(other.keywords, keywords);

  @override
  int get hashCode => Object.hash(id, label, Object.hashAll(keywords));
}

final class SearchResultProjection {
  const SearchResultProjection({
    required this.id,
    required this.title,
    required this.subtitle,
    required this.destination,
    required this.resultKind,
    this.groupId = '',
    this.groupLabel = '',
    this.emphasized = false,
  });

  final String id;
  final String title;
  final String subtitle;
  final ClientSection destination;
  final String resultKind;
  final String groupId;
  final String groupLabel;
  final bool emphasized;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SearchResultProjection &&
          other.id == id &&
          other.title == title &&
          other.subtitle == subtitle &&
          other.destination == destination &&
          other.resultKind == resultKind &&
          other.groupId == groupId &&
          other.groupLabel == groupLabel &&
          other.emphasized == emphasized;

  @override
  int get hashCode => Object.hash(
    id,
    title,
    subtitle,
    destination,
    resultKind,
    groupId,
    groupLabel,
    emphasized,
  );
}

final class SearchProjection {
  SearchProjection({
    required this.query,
    required Iterable<SearchResultProjection> results,
    required this.open,
    required this.phase,
  }) : results = immutablePresentationList(results);

  final String query;
  final List<SearchResultProjection> results;
  final bool open;
  final PresentationPhase phase;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SearchProjection &&
          other.query == query &&
          samePresentationList(other.results, results) &&
          other.open == open &&
          other.phase == phase;

  @override
  int get hashCode => Object.hash(query, Object.hashAll(results), open, phase);
}
