const optionalLocalServerRuntimeCapability =
    'digest-bound-licomesh-server-runner-v1';

void optionalLocalRequirePolicy(
  Map<String, dynamic> json, {
  required bool planned,
}) {
  if (json['runtimeCapability'] != optionalLocalServerRuntimeCapability ||
      json['loopbackOnly'] != true ||
      json['externalFileTransferAuthorized'] != false ||
      (planned
          ? json['pluginCodeWillExecute'] != false ||
                json['preflightPassed'] != true ||
                json['runnerWillExecuteOnlyAfterDirectStartApproval'] != true
          : json['pluginCodeExecuted'] != false)) {
    throw const FormatException('optional_local_server_policy_invalid');
  }
}

String optionalLocalRequiredAdapter(Map<String, dynamic> json) {
  final value = optionalLocalRequiredText(json, 'assemblyAdapterId');
  if (value != 'licoup-builtin-local-http-v1') {
    throw const FormatException('optional_local_server_adapter_invalid');
  }
  return value;
}

String optionalLocalRequiredLoopback(Map<String, dynamic> json) {
  final value = optionalLocalRequiredText(json, 'bindHost');
  if (value != '127.0.0.1') {
    throw const FormatException('optional_local_server_bind_host_invalid');
  }
  return value;
}

String optionalLocalRequiredGitHubSource(
  Map<String, dynamic> json,
  String key,
) {
  final value = optionalLocalRequiredText(json, key);
  final uri = Uri.tryParse(value);
  if (uri == null ||
      uri.scheme != 'https' ||
      uri.host != 'github.com' ||
      !uri.path.endsWith('.git') ||
      uri.hasQuery ||
      uri.hasFragment ||
      uri.userInfo.isNotEmpty) {
    throw FormatException('optional_local_server_${key}_invalid');
  }
  return value;
}

String optionalLocalRequiredText(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! String ||
      value.isEmpty ||
      value != value.trim() ||
      value.length > 4096 ||
      RegExp(r'[\x00-\x1f\x7f]').hasMatch(value)) {
    throw FormatException('optional_local_server_${key}_invalid');
  }
  return value;
}

String optionalLocalRequiredId(Map<String, dynamic> json, String key) {
  final value = optionalLocalRequiredText(json, key);
  if (!RegExp(r'^[a-z0-9-]{1,128}$').hasMatch(value)) {
    throw FormatException('optional_local_server_${key}_invalid');
  }
  return value;
}

String optionalLocalRequiredUuid(Map<String, dynamic> json, String key) {
  final value = optionalLocalRequiredText(json, key);
  if (!RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  ).hasMatch(value)) {
    throw FormatException('optional_local_server_${key}_invalid');
  }
  return value;
}

String optionalLocalRequiredSha256(Map<String, dynamic> json, String key) {
  final value = optionalLocalRequiredText(json, key);
  if (!RegExp(r'^[0-9a-f]{64}$').hasMatch(value)) {
    throw FormatException('optional_local_server_${key}_invalid');
  }
  return value;
}

String optionalLocalRequiredCommitOid(Map<String, dynamic> json, String key) {
  final value = optionalLocalRequiredText(json, key);
  if (!RegExp(r'^[0-9a-f]{40}$').hasMatch(value)) {
    throw FormatException('optional_local_server_${key}_invalid');
  }
  return value;
}

String optionalLocalRequiredAbsolutePath(
  Map<String, dynamic> json,
  String key,
) {
  final value = optionalLocalRequiredText(json, key);
  final absolute =
      value.startsWith('/') ||
      value.startsWith(r'\\') ||
      RegExp(r'^[A-Za-z]:[\\/]').hasMatch(value);
  if (!absolute ||
      value
          .split(RegExp(r'[\\/]'))
          .any((segment) => segment == '.' || segment == '..')) {
    throw FormatException('optional_local_server_${key}_invalid');
  }
  return value;
}

String optionalLocalRequiredRelativePath(
  Map<String, dynamic> json,
  String key,
) {
  final value = optionalLocalRequiredText(json, key);
  if (value.startsWith('/') ||
      value.endsWith('/') ||
      value.contains('\\') ||
      value
          .split('/')
          .any(
            (segment) => segment.isEmpty || segment == '.' || segment == '..',
          )) {
    throw FormatException('optional_local_server_${key}_invalid');
  }
  return value;
}

List<String> optionalLocalRequiredIds(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! List || value.isEmpty || value.length > 256) {
    throw FormatException('optional_local_server_${key}_invalid');
  }
  final ids = value
      .map((item) => optionalLocalRequiredId({'value': item}, 'value'))
      .toList(growable: false);
  if (ids.toSet().length != ids.length) {
    throw FormatException('optional_local_server_${key}_invalid');
  }
  return List.unmodifiable(ids);
}

int optionalLocalPositiveInt(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is! num || value <= 0 || value > 65536) {
    throw FormatException('optional_local_server_${key}_invalid');
  }
  return value.toInt();
}

int optionalLocalRequiredPort(Map<String, dynamic> json) {
  final value = json['port'];
  if (value is! num || value < 1024 || value > 65535) {
    throw const FormatException('optional_local_server_port_invalid');
  }
  return value.toInt();
}

bool optionalLocalSameStrings(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  final a = [...left]..sort();
  final b = [...right]..sort();
  for (var index = 0; index < a.length; index += 1) {
    if (a[index] != b[index]) return false;
  }
  return true;
}
