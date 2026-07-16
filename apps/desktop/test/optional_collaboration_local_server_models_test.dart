import 'package:flutter_client/src/contracts/optional_collaboration_local_server_models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/optional_collaboration_test_fixtures.dart';

const _digest =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _manifestDigest =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

void main() {
  test(
    'assembly plan binds source version components adapter and loopback',
    () {
      final plan = OptionalLocalAssemblyPlan.fromJson(_planJson());
      expect(plan.serverVersion, '1.0.0');
      expect(plan.selectedComponentIds, ['server-core']);
      expect(plan.bindHost, '127.0.0.1');
      expect(plan.runnerContractVersion, 'licoarc.local-server-runner.v1');
      expect(plan.sourceCommitOid, optionalCollaborationTestCommit);
      expect(
        plan.matchesWorkflow(
          expectedPluginId: 'licolite-collaboration',
          expectedPackageDigestSha256: _digest,
          expectedComponentIds: const ['server-core'],
          expectedDestination: '/tmp/licolite-local',
        ),
        isTrue,
      );
    },
  );

  test(
    'assembly plan rejects executable policy drift and non-loopback bind',
    () {
      final executable = _planJson()..['pluginCodeWillExecute'] = true;
      final remoteBind = _planJson()..['bindHost'] = '0.0.0.0';
      expect(
        () => OptionalLocalAssemblyPlan.fromJson(executable),
        throwsFormatException,
      );
      expect(
        () => OptionalLocalAssemblyPlan.fromJson(remoteBind),
        throwsFormatException,
      );
    },
  );

  test('status and mutations retain exact assembly identity', () {
    final status = parseOptionalLocalServerStatus({
      'ok': true,
      'status': 'loaded',
      'servers': [_serverJson()],
    });
    final started = parseOptionalLocalServerMutation({
      'ok': true,
      'status': 'deployment-started',
      'server': _serverJson(status: 'running'),
    }, expectedStatus: 'deployment-started');
    final uninstall = OptionalLocalServerUninstallResult.fromJson({
      'ok': true,
      'status': 'uninstalled',
      'deploymentId': status.single.deploymentId,
      'assemblyManifestDigestSha256': _manifestDigest,
      'cleanupPending': false,
    });
    expect(status.single.isStopped, isTrue);
    expect(started.isRunning, isTrue);
    expect(started.healthVerified, isTrue);
    expect(started.capabilitiesVerified, isTrue);
    expect(started.sameAssemblyAs(status.single), isTrue);
    final drifted = OptionalLocalServerState.fromJson({
      ..._serverJson(status: 'running'),
      'runnerDigestSha256': _manifestDigest,
    });
    expect(drifted.sameAssemblyAs(status.single), isFalse);
    expect(uninstall.assemblyManifestDigestSha256, _manifestDigest);
  });
}

Map<String, dynamic> _planJson() => {
  'deploymentId': '00000000-0000-4000-8000-000000000020',
  'pluginId': 'licolite-collaboration',
  'sourceUrl': 'https://github.com/example/licolite-bundle.git',
  'serverVersion': '1.0.0',
  'packageDigestSha256': _digest,
  'selectedComponentIds': ['server-core'],
  'destination': '/tmp/licolite-local',
  'assemblyAdapterId': 'licoarc-builtin-local-http-v1',
  'assemblyManifestDigestSha256': _manifestDigest,
  'assemblyManifestBytes': 512,
  'bindHost': '127.0.0.1',
  'port': 43121,
  ...optionalCollaborationTestRunnerBindings(digest: _digest, planned: true),
  'loopbackOnly': true,
  'preflightPassed': true,
  'pluginCodeWillExecute': false,
  'externalFileTransferAuthorized': false,
};

Map<String, dynamic> _serverJson({
  String status = 'assembled-awaiting-deployment',
}) => {
  'deploymentId': '00000000-0000-4000-8000-000000000020',
  'status': status,
  'sourceUrl': 'https://github.com/example/licolite-bundle.git',
  'serverVersion': '1.0.0',
  'packageDigestSha256': _digest,
  'selectedComponentIds': ['server-core'],
  'destination': '/tmp/licolite-local',
  'assemblyAdapterId': 'licoarc-builtin-local-http-v1',
  'assemblyManifestDigestSha256': _manifestDigest,
  'bindHost': '127.0.0.1',
  'port': 43121,
  ...optionalCollaborationTestRunnerBindings(
    digest: _digest,
    planned: false,
    status: status,
  ),
  'loopbackOnly': true,
  'pluginCodeExecuted': false,
  'externalFileTransferAuthorized': false,
};
