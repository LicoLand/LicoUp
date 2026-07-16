import 'package:flutter_client/src/contracts/optional_collaboration_local_server_parsing.dart';

final class OptionalLocalServerUninstallResult {
  const OptionalLocalServerUninstallResult({
    required this.deploymentId,
    required this.assemblyManifestDigestSha256,
    required this.cleanupPending,
  });

  final String deploymentId;
  final String assemblyManifestDigestSha256;
  final bool cleanupPending;

  factory OptionalLocalServerUninstallResult.fromJson(
    Map<String, dynamic> json,
  ) {
    if (json['ok'] != true ||
        json['status'] != 'uninstalled' ||
        json['cleanupPending'] is! bool) {
      throw const FormatException(
        'optional_local_server_uninstall_result_invalid',
      );
    }
    return OptionalLocalServerUninstallResult(
      deploymentId: optionalLocalRequiredUuid(json, 'deploymentId'),
      assemblyManifestDigestSha256: optionalLocalRequiredSha256(
        json,
        'assemblyManifestDigestSha256',
      ),
      cleanupPending: json['cleanupPending'] as bool,
    );
  }
}
