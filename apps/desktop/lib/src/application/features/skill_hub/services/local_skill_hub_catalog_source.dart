import 'dart:io';

import 'package:licoup/src/application/features/skill_hub/services/skill_hub_skill_catalog.dart';
import 'package:licoup/src/contracts/skill_hub.dart';

class LocalSkillHubCatalogSource implements SkillHubLocalCatalogSource {
  const LocalSkillHubCatalogSource();

  @override
  Future<List<Map<String, dynamic>>> scan({
    required Iterable<String> detectedAgentIds,
  }) async {
    if (Platform.environment.containsKey('FLUTTER_TEST')) return const [];
    final catalog = SkillHubSkillCatalogBuilder(
      detectedAgentIds: detectedAgentIds,
    );
    final home =
        Platform.environment['HOME'] ??
        Platform.environment['USERPROFILE'] ??
        '';
    await catalog.scanLocalDirectories(
      workspaceRoot: Directory.current.path,
      homeDirectory: home,
    );
    return List.unmodifiable(
      catalog.skills.map((skill) => Map<String, dynamic>.from(skill)),
    );
  }
}
