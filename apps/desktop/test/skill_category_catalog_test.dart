import 'package:flutter_client/src/application/features/skill_hub/models/skill_category_catalog.dart';
import 'package:flutter_client/src/contracts/skill_hub_preferences.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('infers ClawHub-style categories from skill keywords', () {
    expect(
      inferSkillCategorySlug(
        skillId: 'impeccable',
        title: 'impeccable',
        description: 'design, redesign, polish, and animate interfaces',
      ),
      'creative',
    );
    expect(
      inferSkillCategorySlug(
        skillId: 'github',
        title: 'GitHub',
        description: 'Manage issues, pull requests, and git repos',
      ),
      'development',
    );
    expect(
      inferSkillCategorySlug(
        skillId: 'plain-skill',
        title: 'plain-skill',
        description: 'No matching keywords here.',
      ),
      'other',
    );
  });

  test('resolveSkillIconId prefers user overrides', () {
    expect(
      resolveSkillIconId(
        skillId: 'github',
        title: 'GitHub',
        description: 'git repo tools',
        overrideIconId: 'brain',
      ),
      'brain',
    );
    expect(
      resolveSkillIconId(
        skillId: 'github',
        title: 'GitHub',
        description: 'git repo tools',
      ),
      'wrench',
    );
  });

  test('SkillHubPreferences round-trips overrides', () {
    final prefs = SkillHubPreferences.defaults().withOverride(
      'impeccable',
      const SkillVisualOverride(iconId: 'palette', colorToken: 'violet'),
    );
    final restored = SkillHubPreferences.fromJson(prefs.toJson());
    expect(restored.overrideFor('impeccable').iconId, 'palette');
    expect(restored.overrideFor('impeccable').colorToken, 'violet');
    expect(restored.overrideFor('missing').isEmpty, isTrue);
  });
}
