List<Map<String, dynamic>> optionalWorkflowMaps(
  Map<String, dynamic> json,
  String key, {
  required int maxItems,
  bool allowEmpty = false,
}) {
  final value = json[key];
  if (value is! List ||
      (!allowEmpty && value.isEmpty) ||
      value.length > maxItems) {
    throw FormatException('optional_collaboration_${key}_invalid');
  }
  return value
      .map((item) {
        if (item is! Map) {
          throw FormatException('optional_collaboration_${key}_invalid');
        }
        return item.map((key, value) => MapEntry(key.toString(), value));
      })
      .toList(growable: false);
}

Map<String, dynamic> optionalWorkflowRequiredMap(
  Map<String, dynamic> json,
  String key,
) {
  final value = json[key];
  if (value is! Map) {
    throw FormatException('optional_collaboration_${key}_invalid');
  }
  return value.map((key, value) => MapEntry(key.toString(), value));
}

String optionalWorkflowRequiredText(Map<String, dynamic> json, String key) {
  final value = optionalWorkflowOptionalText(json, key);
  if (value.isEmpty ||
      value.length > 4096 ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
    throw FormatException('optional_collaboration_${key}_invalid');
  }
  return value;
}

String optionalWorkflowOptionalText(Map<String, dynamic> json, String key) {
  final value = json[key];
  return value is String && value == value.trim() ? value : '';
}

String optionalWorkflowRequiredId(Map<String, dynamic> json, String key) {
  final value = optionalWorkflowRequiredText(json, key);
  if (value.length > 128 || !RegExp(r'^[a-z0-9-]+$').hasMatch(value)) {
    throw FormatException('optional_collaboration_${key}_invalid');
  }
  return value;
}

String optionalWorkflowRequiredUuid(Map<String, dynamic> json, String key) {
  final value = optionalWorkflowRequiredText(json, key);
  if (!RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  ).hasMatch(value)) {
    throw FormatException('optional_collaboration_${key}_invalid');
  }
  return value;
}

String optionalWorkflowRequiredSha256(Map<String, dynamic> json, String key) {
  final value = optionalWorkflowRequiredText(json, key);
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
    throw FormatException('optional_collaboration_${key}_invalid');
  }
  return value;
}

String optionalWorkflowRequiredAbsolutePath(
  Map<String, dynamic> json,
  String key,
) {
  final value = optionalWorkflowRequiredText(json, key);
  final absolute =
      value.startsWith('/') ||
      value.startsWith(r'\\') ||
      RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value);
  if (!absolute || optionalWorkflowHasTraversalSegment(value)) {
    throw FormatException('optional_collaboration_${key}_invalid');
  }
  return value;
}

String optionalWorkflowRequiredRelativePath(
  Map<String, dynamic> json,
  String key,
) {
  final value = optionalWorkflowRequiredText(json, key);
  if (value.startsWith('/') ||
      value.startsWith(r'\\') ||
      RegExp(r'^[A-Za-z]:').hasMatch(value) ||
      optionalWorkflowHasTraversalSegment(value)) {
    throw FormatException('optional_collaboration_${key}_invalid');
  }
  return value;
}

List<String> optionalWorkflowRequiredIds(
  Map<String, dynamic> json,
  String key,
) {
  final value = json[key];
  if (value is! List || value.isEmpty || value.length > 256) {
    throw FormatException('optional_collaboration_${key}_invalid');
  }
  final result = value
      .map((item) => optionalWorkflowRequiredId({'value': item}, 'value'))
      .toList(growable: false);
  if (result.toSet().length != result.length) {
    throw FormatException('optional_collaboration_${key}_invalid');
  }
  return List.unmodifiable(result);
}

int optionalWorkflowNonNegativeInt(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! num || value < 0 || value > 9007199254740991) {
    throw FormatException('optional_collaboration_${key}_invalid');
  }
  return value.toInt();
}

bool optionalWorkflowHasTraversalSegment(String value) {
  return value
      .split(RegExp(r'[\\/]'))
      .any((segment) => segment == '.' || segment == '..');
}

bool optionalWorkflowSameStrings(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

bool optionalWorkflowSameStringSets(Set<String> left, Set<String> right) {
  return left.length == right.length && left.containsAll(right);
}
