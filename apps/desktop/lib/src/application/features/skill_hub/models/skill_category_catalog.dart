/// ClawHub-aligned skill browse categories and keyword inference.
///
/// Category slugs, icons, and keywords mirror
/// https://clawhub.ai/skills browse categories.
class SkillCategoryDefinition {
  const SkillCategoryDefinition({
    required this.slug,
    required this.label,
    required this.iconId,
    required this.keywords,
  });

  final String slug;
  final String label;
  final String iconId;
  final List<String> keywords;
}

const skillCategoryDefinitions = <SkillCategoryDefinition>[
  SkillCategoryDefinition(
    slug: 'integrations',
    label: 'Integrations',
    iconId: 'plug',
    keywords: [
      'api',
      'data',
      'database',
      'integration',
      'fetch',
      'http',
      'graphql',
    ],
  ),
  SkillCategoryDefinition(
    slug: 'automation',
    label: 'Automation',
    iconId: 'zap',
    keywords: [
      'automation',
      'automate',
      'workflow',
      'workflows',
      'cron',
      'schedule',
      'pipeline',
      'orchestrate',
    ],
  ),
  SkillCategoryDefinition(
    slug: 'research',
    label: 'Research',
    iconId: 'globe',
    keywords: [
      'web',
      'browser',
      'search',
      'scrape',
      'research',
      'crawl',
      'rss',
    ],
  ),
  SkillCategoryDefinition(
    slug: 'development',
    label: 'Development',
    iconId: 'wrench',
    keywords: [
      'developer',
      'debug',
      'lint',
      'test',
      'build',
      'code',
      'git',
      'repo',
    ],
  ),
  SkillCategoryDefinition(
    slug: 'productivity',
    label: 'Productivity',
    iconId: 'list-checks',
    keywords: [
      'task',
      'todo',
      'calendar',
      'email',
      'meeting',
      'project',
      'productivity',
    ],
  ),
  SkillCategoryDefinition(
    slug: 'communication',
    label: 'Communication',
    iconId: 'message-circle',
    keywords: [
      'message',
      'social',
      'discord',
      'slack',
      'telegram',
      'whatsapp',
      'chat',
    ],
  ),
  SkillCategoryDefinition(
    slug: 'creative',
    label: 'Creative',
    iconId: 'palette',
    keywords: [
      'image',
      'video',
      'audio',
      'music',
      'design',
      'creative',
      'writing',
    ],
  ),
  SkillCategoryDefinition(
    slug: 'knowledge',
    label: 'Knowledge',
    iconId: 'book-open',
    keywords: [
      'document',
      'docs',
      'pdf',
      'notes',
      'knowledge',
      'study',
      'learning',
    ],
  ),
  SkillCategoryDefinition(
    slug: 'agents',
    label: 'Agents',
    iconId: 'brain',
    keywords: [
      'agent',
      'memory',
      'planning',
      'reflect',
      'reasoning',
      'context',
    ],
  ),
  SkillCategoryDefinition(
    slug: 'operations',
    label: 'Operations',
    iconId: 'activity',
    keywords: [
      'deploy',
      'observability',
      'monitor',
      'infrastructure',
      'filesystem',
      'shell',
      'terminal',
    ],
  ),
  SkillCategoryDefinition(
    slug: 'security',
    label: 'Security',
    iconId: 'shield',
    keywords: [
      'security',
      'audit',
      'scan',
      'auth',
      'encrypt',
      'policy',
      'secret',
    ],
  ),
  SkillCategoryDefinition(
    slug: 'finance',
    label: 'Finance',
    iconId: 'wallet-cards',
    keywords: [
      'finance',
      'payment',
      'budget',
      'bank',
      'shopping',
      'market',
      'commerce',
    ],
  ),
  SkillCategoryDefinition(
    slug: 'lifestyle',
    label: 'Lifestyle',
    iconId: 'shapes',
    keywords: [
      'travel',
      'health',
      'fitness',
      'cooking',
      'sports',
      'weather',
      'home',
    ],
  ),
  SkillCategoryDefinition(
    slug: 'other',
    label: 'Other',
    iconId: 'package',
    keywords: [],
  ),
];

const skillCategoryIconAssetPrefix = 'assets/skill-category-icons/';

String skillCategoryIconAssetPath(String iconId) {
  return '$skillCategoryIconAssetPrefix$iconId.svg';
}

SkillCategoryDefinition? skillCategoryBySlug(String slug) {
  for (final category in skillCategoryDefinitions) {
    if (category.slug == slug) return category;
  }
  return null;
}

SkillCategoryDefinition? skillCategoryByIconId(String iconId) {
  for (final category in skillCategoryDefinitions) {
    if (category.iconId == iconId) return category;
  }
  return null;
}

/// Infer the best ClawHub-style category from skill title/description/id.
String inferSkillCategorySlug({
  required String skillId,
  String title = '',
  String description = '',
}) {
  final tokens = _tokenizeSkillText('$title $description $skillId');
  if (tokens.isEmpty) return 'other';

  final scored = <({String slug, int score})>[];
  for (final category in skillCategoryDefinitions) {
    if (category.slug == 'other') continue;
    var score = 0;
    for (final keyword in category.keywords) {
      if (tokens.any((token) => _tokensMatch(token, keyword))) {
        score += 1;
      }
    }
    if (score > 0) {
      scored.add((slug: category.slug, score: score));
    }
  }
  if (scored.isEmpty) return 'other';
  scored.sort((a, b) {
    final byScore = b.score.compareTo(a.score);
    if (byScore != 0) return byScore;
    return a.slug.compareTo(b.slug);
  });
  return scored.first.slug;
}

String resolveSkillIconId({
  required String skillId,
  String title = '',
  String description = '',
  String? overrideIconId,
}) {
  final override = overrideIconId?.trim() ?? '';
  if (override.isNotEmpty && skillCategoryByIconId(override) != null) {
    return override;
  }
  final slug = inferSkillCategorySlug(
    skillId: skillId,
    title: title,
    description: description,
  );
  return skillCategoryBySlug(slug)?.iconId ?? 'package';
}

List<String> _tokenizeSkillText(String value) {
  final matches = RegExp(
    r'[\p{L}\p{N}]+',
    unicode: true,
  ).allMatches(value.toLowerCase());
  return [for (final match in matches) match.group(0)!];
}

bool _tokensMatch(String left, String right) {
  return left == right || left == '${right}s' || right == '${left}s';
}
