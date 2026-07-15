import 'package:flutter_client/src/application/features/skill_hub/models/skill_agent_compatibility.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    '.claude skills always identify Claude and detected compatible agents',
    () {
      expect(
        skillLoaderAgentIdsForPath(
          path: '/workspace/.claude/skills/reviewer',
          isPublic: false,
          detectedAgentIds: const ['claude-code', 'opencode', 'cursor'],
        ),
        const ['claude-code', 'opencode'],
      );
    },
  );

  test('.agents skills include every detected compatible agent', () {
    expect(
      skillLoaderAgentIdsForPath(
        path: '/workspace/.agents/skills/reviewer',
        isPublic: true,
        detectedAgentIds: const [
          'codex',
          'claude-code',
          'cursor',
          'kimi-code',
          'hermes',
        ],
      ),
      const ['codex', 'cursor', 'kimi-code'],
    );
  });

  test('generic public catalog never has an empty loader list', () {
    final loaders = skillLoaderAgentIdsForPath(
      path: '/catalog/skills/reviewer',
      isPublic: true,
    );
    expect(loaders, isNotEmpty);
    expect(loaders.toSet().difference(skillCapableAgentIds), isEmpty);
  });

  test('unknown private skill never has an empty loader list', () {
    final loaders = skillLoaderAgentIdsForPath(
      path: ['', 'private', 'skills', 'reviewer'].join('/'),
      isPublic: false,
    );
    expect(loaders, isNotEmpty);
    expect(loaders.toSet().difference(skillCapableAgentIds), isEmpty);
  });

  test('.claude owner is retained without optional compatibility guesses', () {
    expect(
      skillLoaderAgentIdsForPath(
        path: '/workspace/.claude/skills/reviewer',
        isPublic: false,
        detectedAgentIds: const ['kilo-code'],
      ),
      const ['claude-code'],
    );
  });

  test('loader labels use formal product and surface names', () {
    expect(skillLoaderAgentLabel('codex'), 'ChatGPT - Desktop');
    expect(skillLoaderAgentLabel('claude'), 'Claude Code - CLI');
    expect(skillLoaderAgentLabel('github-copilot'), 'GitHub Copilot - Plugin');
    expect(skillLoaderAgentLabel('cursor'), 'Cursor - IDE');
    expect(skillLoaderAgentLabel('opencode'), 'OpenCode - CLI');
  });

  test('agent skill roots use product-specific directory names', () {
    expect(skillDirectorySegmentsForAgent('claude-code'), ['.claude/skills']);
    expect(skillDirectorySegmentsForAgent('kimi-code'), ['.kimi/skills']);
    expect(skillDirectorySegmentsForAgent('opencode'), [
      '.opencode/skills',
      '.config/opencode/skills',
    ]);
  });
}
