Map<String, dynamic> optionalCollaborationRequiredMap(
  Map<String, dynamic> json,
  String key,
) {
  final value = json[key];
  if (value is! Map) {
    throw FormatException('optional_collaboration_${key}_invalid');
  }
  return value.map((mapKey, item) => MapEntry(mapKey.toString(), item));
}

String optionalCollaborationRequiredText(
  Map<String, dynamic> json,
  String key,
) {
  final value = optionalCollaborationOptionalText(json, key);
  if (value.isEmpty || value.length > 4096) {
    throw FormatException('optional_collaboration_${key}_invalid');
  }
  return value;
}

String optionalCollaborationOptionalText(
  Map<String, dynamic> json,
  String key,
) {
  final value = json[key];
  return value is String ? value.trim() : '';
}

int optionalCollaborationNonNegativeInt(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! num || value < 0) {
    throw FormatException('optional_collaboration_${key}_invalid');
  }
  return value.toInt();
}

List<String> optionalCollaborationBoundedStringList(
  Object? value, {
  required int maxItems,
}) {
  if (value is! List || value.isEmpty || value.length > maxItems) {
    throw const FormatException('optional_collaboration_list_invalid');
  }
  final result = <String>[];
  for (final item in value) {
    if (item is! String ||
        item.trim().isEmpty ||
        item.length > 255 ||
        item != item.trim()) {
      throw const FormatException('optional_collaboration_list_invalid');
    }
    result.add(item);
  }
  return List.unmodifiable(result);
}

bool optionalCollaborationIsSha256(String value) {
  return RegExp(r'^[0-9a-f]{64}$').hasMatch(value);
}

bool optionalCollaborationIsCommitOid(String value) {
  return RegExp(r'^[0-9a-f]{40}$').hasMatch(value);
}

bool optionalCollaborationIsRelativePackagePath(String value) {
  if (value.isEmpty ||
      value.length > 1024 ||
      value.startsWith('/') ||
      value.endsWith('/') ||
      value.contains('\\')) {
    return false;
  }
  final segments = value.split('/');
  return segments.every(
    (segment) =>
        segment.isNotEmpty &&
        segment != '.' &&
        segment != '..' &&
        segment != '.git' &&
        !segment.contains(RegExp(r'[\x00-\x1f\x7f]')),
  );
}

bool optionalCollaborationIsGitHubRepositoryUrl(String value) {
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host != 'github.com' ||
      uri.hasQuery ||
      uri.hasFragment ||
      uri.userInfo.isNotEmpty ||
      uri.hasPort) {
    return false;
  }
  final segments = uri.pathSegments
      .where((segment) => segment.isNotEmpty)
      .toList(growable: false);
  if (segments.length != 2) return false;
  final repository = segments[1].endsWith('.git')
      ? segments[1].substring(0, segments[1].length - 4)
      : segments[1];
  return RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(segments[0]) &&
      RegExp(r'^[A-Za-z0-9_.-]+$').hasMatch(repository) &&
      !const {'.', '..'}.contains(segments[0]) &&
      !const {'.', '..'}.contains(repository);
}

void optionalCollaborationRejectExecutableDirectives(Object? value) {
  if (value is Map) {
    for (final entry in value.entries) {
      if (const {
        'argv',
        'command',
        'executable',
        'hook',
        'hooks',
        'process',
        'script',
        'shell',
      }.contains(entry.key.toString())) {
        throw const FormatException(
          'optional_collaboration_executable_directive_rejected',
        );
      }
      optionalCollaborationRejectExecutableDirectives(entry.value);
    }
    return;
  }
  if (value is List) {
    for (final item in value) {
      optionalCollaborationRejectExecutableDirectives(item);
    }
  }
}
