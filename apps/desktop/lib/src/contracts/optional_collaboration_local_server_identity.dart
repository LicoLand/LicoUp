import 'package:licoup/src/contracts/optional_collaboration_local_server_parsing.dart';

final class OptionalLocalRunnerBindings {
  const OptionalLocalRunnerBindings({
    required this.platform,
    required this.architecture,
    required this.sourceRelativePath,
    required this.destinationRelativePath,
    required this.digestSha256,
    required this.runnerContractVersion,
    required this.healthContractVersion,
    required this.capabilitiesContractVersion,
    required this.signedPackageInventoryDigestSha256,
    required this.sourceCommitOid,
    required this.runnerTrustKeyId,
    required this.runnerTrustFingerprintSha256,
  });

  final String platform;
  final String architecture;
  final String sourceRelativePath;
  final String destinationRelativePath;
  final String digestSha256;
  final String runnerContractVersion;
  final String healthContractVersion;
  final String capabilitiesContractVersion;
  final String signedPackageInventoryDigestSha256;
  final String sourceCommitOid;
  final String runnerTrustKeyId;
  final String runnerTrustFingerprintSha256;

  factory OptionalLocalRunnerBindings.fromJson(Map<String, dynamic> json) {
    final platform = optionalLocalRequiredText(json, 'runnerPlatform');
    final architecture = optionalLocalRequiredText(json, 'runnerArchitecture');
    final runnerContract = optionalLocalRequiredText(
      json,
      'runnerContractVersion',
    );
    final healthContract = optionalLocalRequiredText(
      json,
      'healthContractVersion',
    );
    final capabilitiesContract = optionalLocalRequiredText(
      json,
      'capabilitiesContractVersion',
    );
    if (!const {'macos', 'windows', 'ubuntu'}.contains(platform) ||
        !const {'x86_64', 'aarch64'}.contains(architecture) ||
        runnerContract != 'licoup.local-server-runner.v1' ||
        healthContract != 'licoup.local-server-health.v1' ||
        capabilitiesContract != 'licoup.local-server-capabilities.v1') {
      throw const FormatException(
        'optional_local_server_runner_contract_invalid',
      );
    }
    return OptionalLocalRunnerBindings(
      platform: platform,
      architecture: architecture,
      sourceRelativePath: optionalLocalRequiredRelativePath(
        json,
        'runnerSourceRelativePath',
      ),
      destinationRelativePath: optionalLocalRequiredRelativePath(
        json,
        'runnerDestinationRelativePath',
      ),
      digestSha256: optionalLocalRequiredSha256(json, 'runnerDigestSha256'),
      runnerContractVersion: runnerContract,
      healthContractVersion: healthContract,
      capabilitiesContractVersion: capabilitiesContract,
      signedPackageInventoryDigestSha256: optionalLocalRequiredSha256(
        json,
        'signedPackageInventoryDigestSha256',
      ),
      sourceCommitOid: optionalLocalRequiredCommitOid(json, 'sourceCommitOid'),
      runnerTrustKeyId: optionalLocalRequiredId(json, 'runnerTrustKeyId'),
      runnerTrustFingerprintSha256: optionalLocalRequiredSha256(
        json,
        'runnerTrustFingerprintSha256',
      ),
    );
  }
}
