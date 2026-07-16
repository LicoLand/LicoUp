import 'package:flutter_client/src/contracts/optional_collaboration_model_parsing.dart';
import 'package:flutter_client/src/contracts/optional_collaboration_runner_trust_models.dart';

final class OptionalCollaborationInstallPlan {
  const OptionalCollaborationInstallPlan({
    required this.planId,
    required this.sourceUrl,
    required this.sourceRef,
    required this.pluginPath,
    required this.plugin,
    required this.packageDigestSha256,
    required this.fileCount,
    required this.totalBytes,
    required this.expiresAtEpochSeconds,
    required this.requiresDirectConfirmation,
    this.runnerTrust,
  });

  final String planId;
  final String sourceUrl;
  final String sourceRef;
  final String pluginPath;
  final OptionalCollaborationPluginSummary plugin;
  final String packageDigestSha256;
  final int fileCount;
  final int totalBytes;
  final int expiresAtEpochSeconds;
  final bool requiresDirectConfirmation;
  final OptionalCollaborationRunnerTrust? runnerTrust;

  factory OptionalCollaborationInstallPlan.fromJson(Map<String, dynamic> json) {
    final source = optionalCollaborationRequiredMap(json, 'source');
    final plugin = optionalCollaborationRequiredMap(json, 'plugin');
    final digest = optionalCollaborationRequiredText(
      json,
      'packageDigestSha256',
    );
    final sourceUrl = optionalCollaborationRequiredText(source, 'url');
    final sourceRef = optionalCollaborationRequiredText(source, 'ref');
    if (!optionalCollaborationIsSha256(digest) ||
        !optionalCollaborationIsGitHubRepositoryUrl(sourceUrl) ||
        !optionalCollaborationIsCommitOid(sourceRef)) {
      throw const FormatException('optional_collaboration_digest_invalid');
    }
    if (json['requiresDirectConfirmation'] != true) {
      throw const FormatException(
        'optional_collaboration_confirmation_policy_invalid',
      );
    }
    return OptionalCollaborationInstallPlan(
      planId: optionalCollaborationRequiredText(json, 'planId'),
      sourceUrl: sourceUrl,
      sourceRef: sourceRef,
      pluginPath: optionalCollaborationOptionalText(source, 'pluginPath'),
      plugin: OptionalCollaborationPluginSummary.fromJson(plugin),
      packageDigestSha256: digest,
      fileCount: optionalCollaborationNonNegativeInt(json, 'fileCount'),
      totalBytes: optionalCollaborationNonNegativeInt(json, 'totalBytes'),
      expiresAtEpochSeconds: optionalCollaborationNonNegativeInt(
        json,
        'expiresAtEpochSeconds',
      ),
      requiresDirectConfirmation: true,
      runnerTrust: OptionalCollaborationRunnerTrust.fromJson(
        optionalCollaborationRequiredMap(json, 'runnerTrust'),
      ),
    );
  }
}

final class OptionalCollaborationPluginSummary {
  const OptionalCollaborationPluginSummary({
    required this.id,
    required this.displayName,
    required this.version,
    required this.capabilities,
  });

  final String id;
  final String displayName;
  final String version;
  final List<String> capabilities;

  factory OptionalCollaborationPluginSummary.fromJson(
    Map<String, dynamic> json,
  ) {
    return OptionalCollaborationPluginSummary(
      id: optionalCollaborationRequiredText(json, 'pluginId'),
      displayName: optionalCollaborationRequiredText(json, 'displayName'),
      version: optionalCollaborationRequiredText(json, 'version'),
      capabilities: optionalCollaborationBoundedStringList(
        json['capabilities'],
        maxItems: 32,
      ),
    );
  }
}

final class OptionalCollaborationInstallCancellation {
  const OptionalCollaborationInstallCancellation({
    required this.planId,
    required this.cleanupPending,
    required this.idempotentReplay,
  });

  final String planId;
  final bool cleanupPending;
  final bool idempotentReplay;

  factory OptionalCollaborationInstallCancellation.fromJson(
    Map<String, dynamic> json, {
    required OptionalCollaborationInstallPlan expectedPlan,
  }) {
    final planId = optionalCollaborationRequiredText(json, 'planId');
    if (json['ok'] != true ||
        json['status'] != 'cancelled' ||
        json['planConsumed'] != true ||
        json['cleanupPending'] is! bool ||
        json['idempotentReplay'] is! bool ||
        planId != expectedPlan.planId) {
      throw const FormatException(
        'optional_collaboration_install_cancellation_invalid',
      );
    }
    return OptionalCollaborationInstallCancellation(
      planId: planId,
      cleanupPending: json['cleanupPending'] as bool,
      idempotentReplay: json['idempotentReplay'] as bool,
    );
  }
}
