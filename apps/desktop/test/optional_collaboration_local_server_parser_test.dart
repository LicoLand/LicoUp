import 'package:flutter_client/src/contracts/optional_collaboration_local_server_models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/optional_collaboration_test_fixtures.dart';

const _digest =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _manifestDigest =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _deploymentId = '00000000-0000-4000-8000-000000000020';

void main() {
  test('status parser rejects duplicate deployment identities', () {
    expect(
      () => parseOptionalLocalServerStatus({
        'ok': true,
        'status': 'loaded',
        'servers': [_server(), _server()],
      }),
      throwsFormatException,
    );
  });

  test('mutation parser requires the exact lifecycle envelope', () {
    expect(
      () => parseOptionalLocalServerMutation({
        'ok': true,
        'status': 'deployment-stopped',
        'server': _server(),
      }, expectedStatus: 'deployment-started'),
      throwsFormatException,
    );
  });

  test('running state requires both health and capability verification', () {
    final running = _server(status: 'running');
    running['healthVerified'] = false;
    expect(
      () => OptionalLocalServerState.fromJson(running),
      throwsFormatException,
    );
  });
}

Map<String, dynamic> _server({
  String status = 'assembled-awaiting-deployment',
}) => {
  'deploymentId': _deploymentId,
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
