import 'package:flutter_client/src/contracts/optional_collaboration_local_assembly_models.dart';
import 'package:flutter_client/src/contracts/optional_collaboration_local_server_identity.dart';
import 'package:flutter_client/src/contracts/optional_collaboration_local_server_parsing.dart';

final class OptionalLocalServerState {
  const OptionalLocalServerState({
    required this.deploymentId,
    required this.status,
    required this.sourceUrl,
    required this.serverVersion,
    required this.packageDigestSha256,
    required this.selectedComponentIds,
    required this.destination,
    required this.assemblyAdapterId,
    required this.assemblyManifestDigestSha256,
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
    this.healthVerified = false,
    this.capabilitiesVerified = false,
  });

  final String deploymentId;
  final String status;
  final String sourceUrl;
  final String serverVersion;
  final String packageDigestSha256;
  final List<String> selectedComponentIds;
  final String destination;
  final String assemblyAdapterId;
  final String assemblyManifestDigestSha256;
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
  final bool healthVerified;
  final bool capabilitiesVerified;

  bool get isRunning => status == 'running';
  bool get isAwaitingDeployment => status == 'assembled-awaiting-deployment';

  /// Existing façade alias: stopped means assembled and awaiting a separately
  /// approved deployment.
  bool get isStopped => isAwaitingDeployment;

  bool matchesAssemblyPlan(OptionalLocalAssemblyPlan plan) {
    return deploymentId == plan.deploymentId &&
        sourceUrl == plan.sourceUrl &&
        serverVersion == plan.serverVersion &&
        packageDigestSha256 == plan.packageDigestSha256 &&
        optionalLocalSameStrings(
          selectedComponentIds,
          plan.selectedComponentIds,
        ) &&
        destination == plan.destination &&
        assemblyAdapterId == plan.assemblyAdapterId &&
        assemblyManifestDigestSha256 == plan.assemblyManifestDigestSha256 &&
        bindHost == plan.bindHost &&
        port == plan.port &&
        runnerPlatform == plan.runnerPlatform &&
        runnerArchitecture == plan.runnerArchitecture &&
        runnerSourceRelativePath == plan.runnerSourceRelativePath &&
        runnerDestinationRelativePath == plan.runnerDestinationRelativePath &&
        runnerDigestSha256 == plan.runnerDigestSha256 &&
        runnerContractVersion == plan.runnerContractVersion &&
        healthContractVersion == plan.healthContractVersion &&
        capabilitiesContractVersion == plan.capabilitiesContractVersion &&
        signedPackageInventoryDigestSha256 ==
            plan.signedPackageInventoryDigestSha256 &&
        sourceCommitOid == plan.sourceCommitOid &&
        runnerTrustKeyId == plan.runnerTrustKeyId &&
        runnerTrustFingerprintSha256 == plan.runnerTrustFingerprintSha256;
  }

  bool sameAssemblyAs(OptionalLocalServerState other) {
    return deploymentId == other.deploymentId &&
        sourceUrl == other.sourceUrl &&
        serverVersion == other.serverVersion &&
        packageDigestSha256 == other.packageDigestSha256 &&
        optionalLocalSameStrings(
          selectedComponentIds,
          other.selectedComponentIds,
        ) &&
        destination == other.destination &&
        assemblyAdapterId == other.assemblyAdapterId &&
        assemblyManifestDigestSha256 == other.assemblyManifestDigestSha256 &&
        bindHost == other.bindHost &&
        port == other.port &&
        runnerPlatform == other.runnerPlatform &&
        runnerArchitecture == other.runnerArchitecture &&
        runnerSourceRelativePath == other.runnerSourceRelativePath &&
        runnerDestinationRelativePath == other.runnerDestinationRelativePath &&
        runnerDigestSha256 == other.runnerDigestSha256 &&
        runnerContractVersion == other.runnerContractVersion &&
        healthContractVersion == other.healthContractVersion &&
        capabilitiesContractVersion == other.capabilitiesContractVersion &&
        signedPackageInventoryDigestSha256 ==
            other.signedPackageInventoryDigestSha256 &&
        sourceCommitOid == other.sourceCommitOid &&
        runnerTrustKeyId == other.runnerTrustKeyId &&
        runnerTrustFingerprintSha256 == other.runnerTrustFingerprintSha256;
  }

  factory OptionalLocalServerState.fromJson(Map<String, dynamic> json) {
    optionalLocalRequirePolicy(json, planned: false);
    final status = optionalLocalRequiredText(json, 'status');
    if (!const {
      'assembled-awaiting-deployment',
      'deployment-starting',
      'running',
      'deployment-stopping',
    }.contains(status)) {
      throw const FormatException('optional_local_server_status_invalid');
    }
    final healthVerified = json['healthVerified'] == true;
    final capabilitiesVerified = json['capabilitiesVerified'] == true;
    if ((status == 'running') != (healthVerified && capabilitiesVerified) ||
        (status != 'running' && (healthVerified || capabilitiesVerified))) {
      throw const FormatException(
        'optional_local_server_runtime_verification_invalid',
      );
    }
    final bindings = OptionalLocalRunnerBindings.fromJson(json);
    return OptionalLocalServerState(
      deploymentId: optionalLocalRequiredUuid(json, 'deploymentId'),
      status: status,
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
      healthVerified: healthVerified,
      capabilitiesVerified: capabilitiesVerified,
    );
  }
}
