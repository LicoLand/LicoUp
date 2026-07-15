import 'dart:io';

import 'package:flutter_client/src/application/features/skill_hub/services/skill_hub_skill_catalog.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

void main() {
  test('skillAuthorFromFrontmatter prefers top-level then metadata.author', () {
    expect(
      skillAuthorFromFrontmatter({
        'author': 'Top Level',
        'metadata.author': 'Meta',
      }),
      'Top Level',
    );
    expect(
      skillAuthorFromFrontmatter({'metadata.author': 'Meta Author'}),
      'Meta Author',
    );
    expect(skillAuthorFromFrontmatter({'name': 'only-name'}), isNull);
  });

  test(
    'scanLocalDirectories captures metadata.author into skill records',
    () async {
      final root = await Directory.systemTemp.createTemp('skill-hub-author-');
      addTearDown(() async {
        if (await root.exists()) {
          await root.delete(recursive: true);
        }
      });

      final skillDir = Directory(
        p.join(root.path, '.agents', 'skills', 'authored'),
      );
      await skillDir.create(recursive: true);
      await File(p.join(skillDir.path, 'SKILL.md')).writeAsString('''
---
name: authored-skill
description: Has an author.
metadata:
  author: Example Org
  version: "2.0"
---

Body
''');

      final catalog = SkillHubSkillCatalogBuilder(
        detectedAgentIds: const ['codex'],
      );
      await catalog.scanLocalDirectories(
        workspaceRoot: root.path,
        homeDirectory: '',
      );

      final skill = catalog.skills.singleWhere(
        (entry) => entry['skillId'] == 'authored-skill',
      );
      expect(skill['author'], 'Example Org');
      expect(skill['version'], '2.0');
      expect(skill['description'], 'Has an author.');
    },
  );
}
