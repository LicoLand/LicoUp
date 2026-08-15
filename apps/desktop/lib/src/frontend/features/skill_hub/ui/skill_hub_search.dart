/// Prefix-first Skill Hub ranking.
///
/// Name fields ([title], [skillId]) outrank content fields ([description],
/// [content]). Prefix matches outrank substring matches. Higher scores sort
/// first; zero means the skill does not match.
int skillHubSearchScore(Map<String, dynamic> skill, String query) {
  final needle = query.trim().toLowerCase();
  if (needle.isEmpty) {
    return 0;
  }
  final name = _bestFieldMatch(needle, [
    (skill['title'] ?? '').toString(),
    (skill['skillId'] ?? '').toString(),
  ]);
  if (name > 0) {
    return name + 2;
  }
  return _bestFieldMatch(needle, [
    (skill['description'] ?? '').toString(),
    (skill['content'] ?? '').toString(),
  ]);
}

List<Map<String, dynamic>> filterAndRankSkillHubSkills({
  required List<Map<String, dynamic>> skills,
  required String category,
  required String query,
}) {
  final filtered = [
    for (final skill in skills)
      if (_matchesCategory(skill, category)) skill,
  ];
  final needle = query.trim();
  if (needle.isEmpty) {
    return filtered;
  }
  final ranked = <({int score, int index, Map<String, dynamic> skill})>[];
  for (var index = 0; index < filtered.length; index++) {
    final score = skillHubSearchScore(filtered[index], needle);
    if (score > 0) {
      ranked.add((score: score, index: index, skill: filtered[index]));
    }
  }
  ranked.sort((left, right) {
    final byScore = right.score.compareTo(left.score);
    return byScore != 0 ? byScore : left.index.compareTo(right.index);
  });
  return [for (final item in ranked) item.skill];
}

bool _matchesCategory(Map<String, dynamic> skill, String category) {
  final isPublic = skill['isPublic'] == true;
  if (category == 'public') {
    return isPublic;
  }
  if (category == 'private') {
    return !isPublic;
  }
  return true;
}

int _bestFieldMatch(String needle, List<String> fields) {
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
