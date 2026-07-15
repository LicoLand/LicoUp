import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:flutter_client/src/application/features/skill_hub/models/skill_agent_compatibility.dart';

typedef SkillHubScanLogger = void Function(String message);

class SkillHubSkillCatalogBuilder {
  SkillHubSkillCatalogBuilder({required Iterable<String> detectedAgentIds})
    : detectedAgentIds = List.unmodifiable(detectedAgentIds);

  final List<String> detectedAgentIds;
  final Map<String, Map<String, dynamic>> _skills = {};

  Iterable<Map<String, dynamic>> get skills => _skills.values;

  void addOrMergeSkill(
    Map<String, dynamic> skill, {
    bool? isPublic,
    String? agentId,
    Iterable<String> agentIds = const [],
  }) {
    final skillId = (skill['skillId'] ?? skill['id'] ?? '').toString();
    if (skillId.isEmpty) return;

    final path = (skill['path'] ?? '').toString();
    var publicStatus = isPublic ?? true;
    if (isPublic == null && path.isNotEmpty) {
      if (path.contains('.gemini') ||
          path.contains('.config') ||
          path.contains('.codex') ||
          path.contains('.claude')) {
        publicStatus = false;
      }
    }

    final author = _skillAuthorFromMap(skill);
    final existing = _skills[skillId];
    if (existing == null) {
      final merged = <String, dynamic>{
        'skillId': skillId,
        'title': skill['title'] ?? skill['name'] ?? skillId,
        'description': skill['description'] ?? '',
        'version': skill['version'] ?? 'local',
        'path': path,
        'isPublic': publicStatus,
        'usedByAgents': <String>[],
        'author': ?author,
      };
      _mergeAgentIds(merged['usedByAgents'] as List<String>, [
        ?agentId,
        ...agentIds,
      ]);
      _skills[skillId] = merged;
      return;
    }

    _mergeAgentIds(existing['usedByAgents'] as List<String>, [
      ?agentId,
      ...agentIds,
    ]);
    if ((existing['description'] ?? '').toString().isEmpty &&
        skill['description'] != null) {
      existing['description'] = skill['description'];
    }
    if ((existing['path'] ?? '').toString().isEmpty && path.isNotEmpty) {
      existing['path'] = path;
    }
    if ((existing['author'] ?? '').toString().isEmpty && author != null) {
      existing['author'] = author;
    }
  }

  Future<void> scanLocalDirectories({
    required String workspaceRoot,
    required String homeDirectory,
    SkillHubScanLogger? log,
  }) async {
    final visitedDirectories = <String>{};

    Future<void> scanOnce(Directory directory, bool isPublic) async {
      final normalized = p.normalize(directory.path);
      if (visitedDirectories.add(normalized)) {
        await _scanDirectoryForSkills(directory, isPublic, log);
      }
    }

    await _scanSharedDirectories(
      workspaceRoot,
      scanOnce,
      includeContentSkills: true,
    );
    await _scanAgentDirectories(workspaceRoot, scanOnce);
    if (homeDirectory.isNotEmpty) {
      await _scanSharedDirectories(homeDirectory, scanOnce);
      await _scanAgentDirectories(homeDirectory, scanOnce);
    }
  }

  void ensureAgentAttribution() {
    for (final skill in _skills.values) {
      final usedBy = skill['usedByAgents'] as List<String>;
      if (usedBy.isEmpty) {
        usedBy.addAll(
          skillLoaderAgentIdsForPath(
            path: (skill['path'] ?? '').toString(),
            isPublic: skill['isPublic'] == true,
            detectedAgentIds: detectedAgentIds,
          ),
        );
      }
    }
  }

  Future<void> _scanSharedDirectories(
    String root,
    Future<void> Function(Directory directory, bool isPublic) scanOnce, {
    bool includeContentSkills = false,
  }) async {
    if (includeContentSkills) {
      await scanOnce(Directory(p.join(root, 'content', 'skills')), true);
    }
    await scanOnce(Directory(p.join(root, '.agents', 'skills')), true);
    await scanOnce(
      Directory(p.join(root, '.config', 'agents', 'skills')),
      true,
    );
  }

  Future<void> _scanAgentDirectories(
    String root,
    Future<void> Function(Directory directory, bool isPublic) scanOnce,
  ) async {
    for (final agentId in detectedAgentIds) {
      for (final relativePath in skillDirectorySegmentsForAgent(agentId)) {
        await scanOnce(
          Directory(p.joinAll([root, ...relativePath.split('/')])),
          false,
        );
      }
    }
  }

  Future<void> _scanDirectoryForSkills(
    Directory directory,
    bool isPublic,
    SkillHubScanLogger? log,
  ) async {
    if (!await directory.exists()) return;
    try {
      await for (final entity in directory.list(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File || p.basename(entity.path) != 'SKILL.md') continue;
        try {
          final frontmatter = _parseSkillFrontmatter(
            await entity.readAsString(),
          );
          final skillDirectory = entity.parent;
          final skillId =
              frontmatter['name'] ??
              frontmatter['id'] ??
              p.basename(skillDirectory.path);
          final author = skillAuthorFromFrontmatter(frontmatter);
          addOrMergeSkill(
            {
              'skillId': skillId,
              'title': frontmatter['name'] ?? frontmatter['title'] ?? skillId,
              'description': frontmatter['description'] ?? '',
              'version':
                  frontmatter['version'] ??
                  frontmatter['metadata.version'] ??
                  'local',
              'path': skillDirectory.path,
              'author': ?author,
            },
            isPublic: isPublic,
            agentIds: skillLoaderAgentIdsForPath(
              path: skillDirectory.path,
              isPublic: isPublic,
              detectedAgentIds: detectedAgentIds,
            ),
          );
        } catch (error) {
          log?.call('Failed to parse a local SKILL.md: $error');
        }
      }
    } catch (error) {
      log?.call('Failed to scan a local skill directory: $error');
    }
  }
}

void _mergeAgentIds(List<String> usedBy, Iterable<String?> agentIds) {
  for (final value in agentIds) {
    if (value == null) continue;
    final canonical = canonicalSkillAgentId(value);
    if (canonical.isNotEmpty && !usedBy.contains(canonical)) {
      usedBy.add(canonical);
    }
  }
}

Map<String, String> _parseSkillFrontmatter(String content) {
  final result = <String, String>{};
  final trimmed = content.trim();
  if (!trimmed.startsWith('---')) return result;
  final lines = trimmed.split('\n');
  var endIndex = -1;
  for (var index = 1; index < lines.length; index += 1) {
    if (lines[index].trim() == '---') {
      endIndex = index;
      break;
    }
  }
  if (endIndex == -1) return result;
  String? nestedParent;
  for (var index = 1; index < endIndex; index += 1) {
    final rawLine = lines[index];
    final line = rawLine.trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final colonIndex = line.indexOf(':');
    if (colonIndex == -1) continue;
    final key = line.substring(0, colonIndex).trim();
    var value = line.substring(colonIndex + 1).trim();
    if ((value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'"))) {
      value = value.substring(1, value.length - 1);
    }
    final indented = rawLine.startsWith(' ') || rawLine.startsWith('\t');
    if (indented && nestedParent != null) {
      result['$nestedParent.$key'] = value;
      continue;
    }
    nestedParent = key == 'metadata' && value.isEmpty ? 'metadata' : null;
    result[key] = value;
  }
  return result;
}

String? skillAuthorFromFrontmatter(Map<String, String> frontmatter) {
  for (final key in const [
    'author',
    'authors',
    'maintainer',
    'metadata.author',
  ]) {
    final value = frontmatter[key]?.trim() ?? '';
    if (value.isNotEmpty) return value;
  }
  return null;
}

String? _skillAuthorFromMap(Map<String, dynamic> skill) {
  for (final key in const ['author', 'authors', 'maintainer']) {
    final value = (skill[key] ?? '').toString().trim();
    if (value.isNotEmpty) return value;
  }
  final metadata = skill['metadata'];
  if (metadata is Map) {
    final value = (metadata['author'] ?? '').toString().trim();
    if (value.isNotEmpty) return value;
  }
  return null;
}
