import 'package:licoup/src/contracts/optional_collaboration_models.dart';

const optionalCollaborationTestCommit =
    '0123456789abcdef0123456789abcdef01234567';
const optionalCollaborationTestRunnerRepository =
    'https://github.com/example/licomesh-runner.git';
const optionalCollaborationTestRunnerPublicKey =
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const optionalCollaborationTestRunnerFingerprint =
    '66687aadf862bd776c8fc18b8e9f8e20089714856ee233b3902a591d0d5f2925';
const optionalCollaborationTestRunnerKeyId = 'official-runner-key';

const optionalCollaborationTestRunnerTrust = OptionalCollaborationRunnerTrust(
  keyId: optionalCollaborationTestRunnerKeyId,
  fingerprintSha256: optionalCollaborationTestRunnerFingerprint,
  sourceRepositoryUrl: optionalCollaborationTestRunnerRepository,
  runnerIdentity: optionalCollaborationOfficialRunnerIdentity,
);

Map<String, dynamic> optionalCollaborationTestRunnerTrustJson() => {
  'keyId': optionalCollaborationTestRunnerKeyId,
  'fingerprintSha256': optionalCollaborationTestRunnerFingerprint,
  'sourceRepositoryUrl': optionalCollaborationTestRunnerRepository,
  'runnerIdentity': optionalCollaborationOfficialRunnerIdentity,
};

Map<String, dynamic> optionalCollaborationTestPluginSecurityFields({
  required String signedInventoryDigest,
}) => {
  'signedPackageInventoryDigestSha256': signedInventoryDigest,
  'sourceCommitOid': optionalCollaborationTestCommit,
  'runnerTrustKeyId': optionalCollaborationTestRunnerKeyId,
  'runnerTrustFingerprintSha256': optionalCollaborationTestRunnerFingerprint,
};

Map<String, dynamic> optionalCollaborationTestRunnerBindings({
  required String digest,
  required bool planned,
  String status = 'assembled-awaiting-deployment',
  String? signedInventoryDigest,
}) => {
  'runtimeCapability': 'digest-bound-licomesh-server-runner-v1',
  'runnerPlatform': 'macos',
  'runnerArchitecture': 'aarch64',
  'runnerSourceRelativePath': 'runners/macos/aarch64/licomesh-server-runner',
  'runnerDestinationRelativePath': 'runtime/licomesh-server-runner',
  'runnerDigestSha256': digest,
  'runnerContractVersion': 'licoup.local-server-runner.v1',
  'healthContractVersion': 'licoup.local-server-health.v1',
  'capabilitiesContractVersion': 'licoup.local-server-capabilities.v1',
  'signedPackageInventoryDigestSha256': signedInventoryDigest ?? digest,
  'sourceCommitOid': optionalCollaborationTestCommit,
  'runnerTrustKeyId': optionalCollaborationTestRunnerKeyId,
  'runnerTrustFingerprintSha256': optionalCollaborationTestRunnerFingerprint,
  if (planned) 'runnerWillExecuteOnlyAfterDirectStartApproval': true,
  if (!planned) 'healthVerified': status == 'running',
  if (!planned) 'capabilitiesVerified': status == 'running',
};
