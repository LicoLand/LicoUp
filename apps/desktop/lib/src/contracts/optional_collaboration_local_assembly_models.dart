import 'package:flutter_client/src/contracts/optional_collaboration_local_server_identity.dart';
import 'package:flutter_client/src/contracts/optional_collaboration_local_server_parsing.dart';

final class OptionalLocalAssemblyPlan {
  const OptionalLocalAssemblyPlan({
    required this.deploymentId,
    required this.pluginId,
    required this.sourceUrl,
    required this.serverVersion,
    required this.packageDigestSha256,
    required this.selectedComponentIds,
    required this.destination,
    required this.assemblyAdapterId,
    required this.assemblyManifestDigestSha256,
    required this.assemblyManifestBytes,
    required this.bindHost,
    required this.port,
    this.runnerPlatform = '',
    this.runnerArchitecture = '',
    this.runnerSourceRelativePath = '',
    this.runnerDestinationRelativePath = '',
    this.runnerDigestSha256 = '',
    this.runnerContractVersion = '',
    this.healthContractVersion = '',
    this.capabilitiesContractVersion = '',
    this.signedPackageInventoryDigestSha256 = '',
    this.sourceCommitOid = '',
    this.runnerTrustKeyId = '',
    this.runnerTrustFingerprintSha256 = '',
  });

  final String deploymentId;
  final String pluginId;
  final String sourceUrl;
  final String serverVersion;
  final String packageDigestSha256;
  final List<String> selectedComponentIds;
  final String destination;
  final String assemblyAdapterId;
  final String assemblyManifestDigestSha256;
  final int assemblyManifestBytes;
  final String bindHost;
  final int port;
  final String runnerPlatform;
  final String runnerArchitecture;
  final String runnerSourceRelativePath;
  final String runnerDestinationRelativePath;
  final String runnerDigestSha256;
  final String runnerContractVersion;
  final String healthContractVersion;
  final String capabilitiesContractVersion;
  final String signedPackageInventoryDigestSha256;
  final String sourceCommitOid;
  final String runnerTrustKeyId;
  final String runnerTrustFingerprintSha256;

  factory OptionalLocalAssemblyPlan.fromJson(Map<String, dynamic> json) {
    optionalLocalRequirePolicy(json, planned: true);
    final bindings = OptionalLocalRunnerBindings.fromJson(json);
    return OptionalLocalAssemblyPlan(
      deploymentId: optionalLocalRequiredUuid(json, 'deploymentId'),
      pluginId: optionalLocalRequiredId(json, 'pluginId'),
      sourceUrl: optionalLocalRequiredGitHubSource(json, 'sourceUrl'),
      serverVersion: optionalLocalRequiredText(json, 'serverVersion'),
      packageDigestSha256: optionalLocalRequiredSha256(
        json,
        'packageDigestSha256',
      ),
      selectedComponentIds: optionalLocalRequiredIds(
        json,
        'selectedComponentIds',
      ),
      destination: optionalLocalRequiredAbsolutePath(json, 'destination'),
      assemblyAdapterId: optionalLocalRequiredAdapter(json),
      assemblyManifestDigestSha256: optionalLocalRequiredSha256(
        json,
        'assemblyManifestDigestSha256',
      ),
      assemblyManifestBytes: optionalLocalPositiveInt(
        json,
        'assemblyManifestBytes',
      ),
      bindHost: optionalLocalRequiredLoopback(json),
      port: optionalLocalRequiredPort(json),
      runnerPlatform: bindings.platform,
      runnerArchitecture: bindings.architecture,
      runnerSourceRelativePath: bindings.sourceRelativePath,
      runnerDestinationRelativePath: bindings.destinationRelativePath,
      runnerDigestSha256: bindings.digestSha256,
      runnerContractVersion: bindings.runnerContractVersion,
      healthContractVersion: bindings.healthContractVersion,
      capabilitiesContractVersion: bindings.capabilitiesContractVersion,
      signedPackageInventoryDigestSha256:
          bindings.signedPackageInventoryDigestSha256,
      sourceCommitOid: bindings.sourceCommitOid,
      runnerTrustKeyId: bindings.runnerTrustKeyId,
      runnerTrustFingerprintSha256: bindings.runnerTrustFingerprintSha256,
    );
  }

  bool matchesWorkflow({
    required String expectedPluginId,
    required String expectedPackageDigestSha256,
    required List<String> expectedComponentIds,
    required String expectedDestination,
  }) {
    return pluginId == expectedPluginId &&
        packageDigestSha256 == expectedPackageDigestSha256 &&
        optionalLocalSameStrings(selectedComponentIds, expectedComponentIds) &&
        destination == expectedDestination;
  }
}
