import 'package:flutter_client/src/contracts/optional_collaboration_model_parsing.dart';

const optionalCollaborationOfficialRunnerIdentity =
    'licolite.official-local-server-runner.v1';

final class OptionalCollaborationRunnerTrust {
  const OptionalCollaborationRunnerTrust({
    required this.keyId,
    required this.fingerprintSha256,
    this.sourceRepositoryUrl = '',
    this.runnerIdentity = '',
  });

  final String keyId;
  final String fingerprintSha256;
  final String sourceRepositoryUrl;
  final String runnerIdentity;

  factory OptionalCollaborationRunnerTrust.fromJson(Map<String, dynamic> json) {
    final keyId = optionalCollaborationRequiredText(json, 'keyId');
    final fingerprint = optionalCollaborationRequiredText(
      json,
      'fingerprintSha256',
    );
    final sourceRepositoryUrl = optionalCollaborationRequiredText(
      json,
      'sourceRepositoryUrl',
    );
    final runnerIdentity = optionalCollaborationRequiredText(
      json,
      'runnerIdentity',
    );
    if (!RegExp(r'^[a-z0-9-]{1,128}$').hasMatch(keyId) ||
        !optionalCollaborationIsSha256(fingerprint) ||
        !optionalCollaborationIsGitHubRepositoryUrl(sourceRepositoryUrl) ||
        runnerIdentity != optionalCollaborationOfficialRunnerIdentity) {
      throw const FormatException(
        'optional_collaboration_runner_trust_invalid',
      );
    }
    return OptionalCollaborationRunnerTrust(
      keyId: keyId,
      fingerprintSha256: fingerprint,
      sourceRepositoryUrl: sourceRepositoryUrl,
      runnerIdentity: runnerIdentity,
    );
  }

  bool sameAs(OptionalCollaborationRunnerTrust other) {
    return keyId == other.keyId &&
        fingerprintSha256 == other.fingerprintSha256 &&
        sourceRepositoryUrl == other.sourceRepositoryUrl &&
        runnerIdentity == other.runnerIdentity;
  }
}

final class OptionalCollaborationRunnerTrustMutation {
  const OptionalCollaborationRunnerTrustMutation({
    required this.status,
    required this.fingerprintSha256,
    required this.keyId,
    required this.idempotent,
    required this.sourceRepositoryUrl,
    required this.runnerIdentity,
  });

  final String status;
  final String fingerprintSha256;
  final String keyId;
  final bool idempotent;
  final String sourceRepositoryUrl;
  final String runnerIdentity;

  bool get imported => status == 'runner-trust-imported';

  OptionalCollaborationRunnerTrust? get trust => imported
      ? OptionalCollaborationRunnerTrust(
          keyId: keyId,
          fingerprintSha256: fingerprintSha256,
          sourceRepositoryUrl: sourceRepositoryUrl,
          runnerIdentity: runnerIdentity,
        )
      : null;

  factory OptionalCollaborationRunnerTrustMutation.fromJson(
    Map<String, dynamic> json,
  ) {
    final status = optionalCollaborationRequiredText(json, 'status');
    final fingerprint = optionalCollaborationRequiredText(
      json,
      'fingerprintSha256',
    );
    final keyId = optionalCollaborationOptionalText(json, 'keyId');
    final sourceRepositoryUrl = optionalCollaborationRequiredText(
      json,
      'sourceRepositoryUrl',
    );
    final runnerIdentity = optionalCollaborationRequiredText(
      json,
      'runnerIdentity',
    );
    if (json['ok'] != true ||
        !const {
          'runner-trust-imported',
          'runner-trust-removed',
        }.contains(status) ||
        !optionalCollaborationIsSha256(fingerprint) ||
        !optionalCollaborationIsGitHubRepositoryUrl(sourceRepositoryUrl) ||
        runnerIdentity != optionalCollaborationOfficialRunnerIdentity ||
        (status == 'runner-trust-imported' &&
            !RegExp(r'^[a-z0-9-]{1,128}$').hasMatch(keyId)) ||
        (status == 'runner-trust-removed' && keyId.isNotEmpty)) {
      throw const FormatException(
        'optional_collaboration_runner_trust_mutation_invalid',
      );
    }
    final idempotentValue = json['idempotent'];
    if (idempotentValue != null && idempotentValue is! bool) {
      throw const FormatException(
        'optional_collaboration_runner_trust_mutation_invalid',
      );
    }
    return OptionalCollaborationRunnerTrustMutation(
      status: status,
      fingerprintSha256: fingerprint,
      keyId: keyId,
      idempotent: idempotentValue == true,
      sourceRepositoryUrl: sourceRepositoryUrl,
      runnerIdentity: runnerIdentity,
    );
  }
}
