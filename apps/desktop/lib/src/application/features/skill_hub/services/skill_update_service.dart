import 'package:flutter_client/src/contracts/skill_update.dart';

/// Explicit user-operated manual and configured skill updates.
final class SkillUpdateService {
  const SkillUpdateService({required SkillUpdateGateway gateway})
    : _gateway = gateway;

  final SkillUpdateGateway _gateway;

  Future<Map<String, dynamic>> plan({
    required String agent,
    required String skillId,
    String githubUrl = '',
    String mirrorPath = '',
    String installRoot = '',
  }) {
    final source = _source(githubUrl: githubUrl, mirrorPath: mirrorPath);
    return _gateway.planSkillUpdate(
      agent: _required(agent, 'agent'),
      skillId: _required(skillId, 'skillId'),
      url: source.githubUrl,
      sourcePath: source.mirrorPath,
      installRoot: installRoot.trim(),
    );
  }

  Future<Map<String, dynamic>> apply({
    required String agent,
    required String skillId,
    required String confirmation,
    String githubUrl = '',
    String mirrorPath = '',
    String installRoot = '',
  }) {
    final source = _source(githubUrl: githubUrl, mirrorPath: mirrorPath);
    return _gateway.applySkillUpdate(
      agent: _required(agent, 'agent'),
      skillId: _required(skillId, 'skillId'),
      confirmation: _required(confirmation, 'confirmation'),
      url: source.githubUrl,
      sourcePath: source.mirrorPath,
      installRoot: installRoot.trim(),
    );
  }

  Future<Map<String, dynamic>> configure({
    required String agent,
    required String skillId,
    required bool enabled,
    String githubUrl = '',
    String mirrorPath = '',
  }) {
    final source = _source(githubUrl: githubUrl, mirrorPath: mirrorPath);
    return _gateway.configureSkillAutoUpdate(
      agent: _required(agent, 'agent'),
      skillId: _required(skillId, 'skillId'),
      enabled: enabled,
      url: source.githubUrl,
      sourcePath: source.mirrorPath,
    );
  }

  Future<Map<String, dynamic>> run({
    required String agent,
    String skillId = '',
  }) {
    return _gateway.runConfiguredSkillUpdates(
      agent: _required(agent, 'agent'),
      skillId: skillId.trim(),
    );
  }
}

({String githubUrl, String mirrorPath}) _source({
  required String githubUrl,
  required String mirrorPath,
}) {
  final github = githubUrl.trim();
  final mirror = mirrorPath.trim();
  if (github.isNotEmpty && mirror.isNotEmpty) {
    throw ArgumentError('Select either a GitHub repository or a mirror.');
  }
  return (githubUrl: github, mirrorPath: mirror);
}

String _required(String value, String name) {
  final normalized = value.trim();
  if (normalized.isEmpty) throw ArgumentError.value(value, name);
  return normalized;
}
