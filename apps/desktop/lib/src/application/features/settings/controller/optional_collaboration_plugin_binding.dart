import 'package:licoup/src/contracts/optional_collaboration_models.dart';

bool optionalCollaborationPluginMatchesInstallPlan(
  OptionalCollaborationPlugin plugin,
  OptionalCollaborationInstallPlan plan,
  OptionalCollaborationRunnerTrust trust,
) {
  return plugin.id == plan.plugin.id &&
      plugin.displayName == plan.plugin.displayName &&
      plugin.version == plan.plugin.version &&
      optionalCollaborationSameCapabilities(
        plugin.capabilities,
        plan.plugin.capabilities,
      ) &&
      plugin.packageDigestSha256 == plan.packageDigestSha256 &&
      optionalCollaborationSameGitHubRepository(
        plugin.sourceUrl,
        plan.sourceUrl,
      ) &&
      plugin.sourceCommitOid == plan.sourceRef &&
      plugin.runnerTrustKeyId == trust.keyId &&
      plugin.runnerTrustFingerprintSha256 == trust.fingerprintSha256;
}

bool optionalCollaborationSameInstalledPlugin(
  OptionalCollaborationPlugin left,
  OptionalCollaborationPlugin right,
) {
  return left.id == right.id &&
      left.displayName == right.displayName &&
      left.version == right.version &&
      left.packageDigestSha256 == right.packageDigestSha256 &&
      optionalCollaborationSameCapabilities(
        left.capabilities,
        right.capabilities,
      ) &&
      left.sourceUrl == right.sourceUrl &&
      left.sourceCommitOid == right.sourceCommitOid &&
      left.signedPackageInventoryDigestSha256 ==
          right.signedPackageInventoryDigestSha256 &&
      left.runnerTrustKeyId == right.runnerTrustKeyId &&
      left.runnerTrustFingerprintSha256 == right.runnerTrustFingerprintSha256;
}

bool optionalCollaborationSameGitHubRepository(String left, String right) {
  String normalize(String value) {
    final trimmed = value.trim();
    return trimmed.endsWith('.git')
        ? trimmed.substring(0, trimmed.length - 4)
        : trimmed;
  }

  return normalize(left) == normalize(right);
}

bool optionalCollaborationSameCapabilities(
  List<String> left,
  List<String> right,
) {
  return left.length == right.length && left.toSet().containsAll(right);
}
