import 'package:licoup/src/frontend/features/agents/ui/history_session_models.dart';

List<HistorySessionPanelItem> historySessionPrefixMatches(
  List<HistorySessionPanelItem> items,
  String query,
) {
  final terms = _searchTerms(query);
  if (terms.isEmpty) return items;

  final ranked = <_HistorySessionSearchMatch>[];
  for (var index = 0; index < items.length; index++) {
    final score = _matchScore(items[index], terms);
    if (score != null) {
      ranked.add(
        _HistorySessionSearchMatch(
          item: items[index],
          originalIndex: index,
          score: score,
        ),
      );
    }
  }
  ranked.sort((a, b) {
    final scoreOrder = a.score.compareTo(b.score);
    return scoreOrder == 0
        ? a.originalIndex.compareTo(b.originalIndex)
        : scoreOrder;
  });
  return ranked.map((match) => match.item).toList(growable: false);
}

final class _HistorySessionSearchMatch {
  const _HistorySessionSearchMatch({
    required this.item,
    required this.originalIndex,
    required this.score,
  });

  final HistorySessionPanelItem item;
  final int originalIndex;
  final int score;
}

final RegExp _searchSeparators = RegExp(r'[\s\/\\._:;,+()\[\]{}<>|\-]+');
final RegExp _searchWord = RegExp(r'[a-z0-9]+');

List<String> _searchTerms(String query) {
  return query
      .toLowerCase()
      .split(_searchSeparators)
      .map((term) => term.trim())
      .where((term) => term.isNotEmpty)
      .toList(growable: false);
}

int? _matchScore(HistorySessionPanelItem item, List<String> terms) {
  var totalScore = 0;
  for (final term in terms) {
    final termScore =
        [
          _fieldMatchScore(item.title, term, 0),
          _fieldMatchScore(item.groupLabel, term, 40),
          _fieldMatchScore(item.meta, term, 80),
          _fieldMatchScore(item.preview, term, 120),
        ].whereType<int>().fold<int?>(
          null,
          (best, score) => best == null || score < best ? score : best,
        );
    if (termScore == null) return null;
    totalScore += termScore;
  }
  return totalScore;
}

int? _fieldMatchScore(String value, String term, int fieldWeight) {
  final text = value.toLowerCase();
  if (text.isEmpty) return null;
  if (text == term) return fieldWeight;
  if (text.startsWith(term)) return fieldWeight + 1;
  for (final match in _searchWord.allMatches(text)) {
    final word = match.group(0);
    if (word != null && word.startsWith(term)) {
      return fieldWeight + 20 + match.start;
    }
  }
  final containsAt = text.indexOf(term);
  return containsAt < 0 ? null : fieldWeight + 200 + containsAt;
}
