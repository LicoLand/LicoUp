import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/frontend/features/skill_hub/ui/skill_hub_search.dart';

void main() {
  const skills = [
    {
      'skillId': 'helper-alpha',
      'title': 'Helper Alpha',
      'description': 'Unrelated notes.',
      'isPublic': true,
    },
    {
      'skillId': 'alpha-writer',
      'title': 'Alpha Writer',
      'description': 'Unrelated notes.',
      'isPublic': true,
    },
    {
      'skillId': 'other',
      'title': 'Other',
      'description': 'Alpha notes for reviews.',
      'isPublic': false,
    },
    {
      'skillId': 'zeta',
      'title': 'Zeta',
      'description': 'Uses Alpha daily.',
      'isPublic': false,
    },
  ];

  test('empty query keeps category order', () {
    final ranked = filterAndRankSkillHubSkills(
      skills: skills,
      category: 'all',
      query: '  ',
    );
    expect(ranked.map((skill) => skill['title']), [
      'Helper Alpha',
      'Alpha Writer',
      'Other',
      'Zeta',
    ]);
  });

  test('prefix name matches outrank substring and content matches', () {
    final ranked = filterAndRankSkillHubSkills(
      skills: skills,
      category: 'all',
      query: 'Alpha',
    );
    expect(ranked.map((skill) => skill['title']), [
      'Alpha Writer',
      'Helper Alpha',
      'Other',
      'Zeta',
    ]);
  });

  test('name matches outrank content even when content is a prefix', () {
    expect(skillHubSearchScore(skills[0], 'Alpha'), 3);
    expect(skillHubSearchScore(skills[1], 'Alpha'), 4);
    expect(skillHubSearchScore(skills[2], 'Alpha'), 2);
    expect(skillHubSearchScore(skills[3], 'Alpha'), 1);
  });

  test('category filter still applies before ranking', () {
    final ranked = filterAndRankSkillHubSkills(
      skills: skills,
      category: 'public',
      query: 'Alpha',
    );
    expect(ranked.map((skill) => skill['title']), [
      'Alpha Writer',
      'Helper Alpha',
    ]);
  });

  test('skill id is treated as a name field', () {
    expect(
      skillHubSearchScore(const {
        'skillId': 'review-helper',
        'title': 'Other Name',
        'description': '',
      }, 'review'),
      4,
    );
  });
}
