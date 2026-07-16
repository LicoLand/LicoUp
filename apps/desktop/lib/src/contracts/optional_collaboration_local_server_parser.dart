import 'package:flutter_client/src/contracts/optional_collaboration_local_server_state.dart';

List<OptionalLocalServerState> parseOptionalLocalServerStatus(
  Map<String, dynamic> json,
) {
  final values = json['servers'];
  if (json['ok'] != true ||
      json['status'] != 'loaded' ||
      values is! List ||
      values.length > 8) {
    throw const FormatException('optional_local_server_status_invalid');
  }
  final servers = values
      .map((value) {
        if (value is! Map) {
          throw const FormatException('optional_local_server_status_invalid');
        }
        return OptionalLocalServerState.fromJson(
          value.map((key, item) => MapEntry(key.toString(), item)),
        );
      })
      .toList(growable: false);
  if (servers.map((server) => server.deploymentId).toSet().length !=
      servers.length) {
    throw const FormatException('optional_local_server_status_invalid');
  }
  return List.unmodifiable(servers);
}

OptionalLocalServerState parseOptionalLocalServerMutation(
  Map<String, dynamic> json, {
  required String expectedStatus,
}) {
  if (json['ok'] != true || json['status'] != expectedStatus) {
    throw const FormatException('optional_local_server_mutation_invalid');
  }
  final server = json['server'];
  if (server is! Map) {
    throw const FormatException('optional_local_server_mutation_invalid');
  }
  return OptionalLocalServerState.fromJson(
    server.map((key, item) => MapEntry(key.toString(), item)),
  );
}
