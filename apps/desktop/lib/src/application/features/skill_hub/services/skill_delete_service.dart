import 'package:flutter_client/src/contracts/skill_delete.dart';

final class SkillDeleteService {
  const SkillDeleteService({required SkillDeleteGateway gateway})
    : _gateway = gateway;

  final SkillDeleteGateway _gateway;

  Future<Map<String, dynamic>> plan({
    required Iterable<String> agents,
    required String skillId,
    String installRoot = '',
  }) {
    return _gateway.planSkillDelete(
      agents: _agents(agents),
      skillId: _required(skillId, 'skillId'),
      installRoot: installRoot.trim(),
    );
  }

  Future<Map<String, dynamic>> apply({
    required Iterable<String> agents,
    required String skillId,
    required String confirmation,
    String installRoot = '',
  }) {
    return _gateway.applySkillDelete(
      agents: _agents(agents),
      skillId: _required(skillId, 'skillId'),
      confirmation: _required(confirmation, 'confirmation'),
      installRoot: installRoot.trim(),
    );
  }
}

List<String> _agents(Iterable<String> values) {
  final result =
      values
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty)
          .toSet()
          .toList()
        ..sort();
  if (result.isEmpty) throw ArgumentError('Select at least one agent.');
  return List.unmodifiable(result);
}

String _required(String value, String name) {
  final normalized = value.trim();
  if (normalized.isEmpty) throw ArgumentError.value(value, name);
  return normalized;
}
