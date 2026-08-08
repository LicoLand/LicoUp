import 'package:licoup/src/contracts/skill_delete.dart';

final class SkillDeleteService {
  const SkillDeleteService({required SkillDeleteGateway gateway})
    : _gateway = gateway;

  final SkillDeleteGateway _gateway;

  Future<Map<String, dynamic>> plan({
    required String skillId,
    required String path,
  }) {
    return _gateway.planSkillDelete(
      skillId: _required(skillId, 'skillId'),
      path: _required(path, 'path'),
    );
  }

  Future<Map<String, dynamic>> apply({
    required String skillId,
    required String path,
    required String confirmation,
  }) {
    return _gateway.applySkillDelete(
      skillId: _required(skillId, 'skillId'),
      path: _required(path, 'path'),
      confirmation: _required(confirmation, 'confirmation'),
    );
  }
}

String _required(String value, String name) {
  final normalized = value.trim();
  if (normalized.isEmpty) throw ArgumentError.value(value, name);
  return normalized;
}
