import 'package:licoup/src/backend/features/settings/services/optional_collaboration_service.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/contracts/optional_collaboration_models.dart';
import 'package:flutter_test/flutter_test.dart';

const _digest =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _sourceUrl = 'https://github.com/example/collaboration-plugin.git';
const _commit = '0123456789abcdef0123456789abcdef01234567';
const _runnerRepository = 'https://github.com/example/licomesh-runner.git';
const _runnerPublicKey = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _runnerFingerprint =
    '66687aadf862bd776c8fc18b8e9f8e20089714856ee233b3902a591d0d5f2925';

void main() {
  test(
    'native adapter uses fixed lifecycle commands and exact digest binding',
    () async {
      final runner = _RecordingRunner();
      final service = OptionalCollaborationService(runner: runner);

      await service.status();
      await service.enable(confirmed: true);
      await service.importRunnerTrust(
        keyId: 'official-runner-key',
        publicKeyBase64url: _runnerPublicKey,
        sourceRepositoryUrl: _runnerRepository,
        runnerIdentity: optionalCollaborationOfficialRunnerIdentity,
        expectedFingerprintSha256: _runnerFingerprint,
        confirmed: true,
      );
      final plan = await service.planInstall(
        githubUrl: ' https://github.com/example/collaboration-plugin ',
        gitRef: ' $_commit ',
        pluginPath: ' plugin ',
        confirmed: true,
      );
      await service.cancelInstall(plan: plan, confirmed: true);
      await service.applyInstall(
        planId: '00000000-0000-4000-8000-000000000000',
        expectedDigestSha256: _digest,
        confirmed: true,
      );
      await service.loadWorkflowCatalog();
      await service.disable(confirmed: true);
      await service.uninstall(expectedDigestSha256: _digest, confirmed: true);
      await service.removeRunnerTrust(
        expectedFingerprintSha256: _runnerFingerprint,
        expectedSourceRepositoryUrl: _runnerRepository,
        expectedRunnerIdentity: optionalCollaborationOfficialRunnerIdentity,
        confirmed: true,
      );

      expect(runner.commands, [
        ['collaboration', 'status'],
        [
          'collaboration',
          'enable',
          '--request-origin',
          'direct-user',
          '--confirmed',
          'true',
        ],
        [
          'collaboration',
          'runner-trust',
          'import',
          '--request-origin',
          'direct-user',
          '--runner-trust-key-id',
          'official-runner-key',
          '--runner-trust-public-key-base64url',
          _runnerPublicKey,
          '--runner-source-repository-url',
          _runnerRepository,
          '--runner-identity',
          optionalCollaborationOfficialRunnerIdentity,
          '--expected-runner-trust-fingerprint-sha256',
          _runnerFingerprint,
          '--confirmed',
          'true',
        ],
        [
          'collaboration',
          'install',
          'plan',
          '--request-origin',
          'direct-user',
          '--github-url',
          'https://github.com/example/collaboration-plugin',
          '--ref',
          _commit,
          '--confirmed',
          'true',
          '--plugin-path',
          'plugin',
        ],
        [
          'collaboration',
          'install',
          'cancel',
          '--request-origin',
          'direct-user',
          '--plan-id',
          '00000000-0000-4000-8000-000000000000',
          '--expected-digest-sha256',
          _digest,
          '--confirmed',
          'true',
        ],
        [
          'collaboration',
          'install',
          'apply',
          '--request-origin',
          'direct-user',
          '--plan-id',
          '00000000-0000-4000-8000-000000000000',
          '--expected-digest-sha256',
          _digest,
          '--confirmed',
          'true',
        ],
        ['collaboration', 'workflow', 'catalog'],
        [
          'collaboration',
          'disable',
          '--request-origin',
          'direct-user',
          '--confirmed',
          'true',
        ],
        [
          'collaboration',
          'uninstall',
          '--request-origin',
          'direct-user',
          '--expected-digest-sha256',
          _digest,
          '--confirmed',
          'true',
        ],
        [
          'collaboration',
          'runner-trust',
          'remove',
          '--request-origin',
          'direct-user',
          '--expected-runner-trust-fingerprint-sha256',
          _runnerFingerprint,
          '--expected-runner-source-repository-url',
          _runnerRepository,
          '--expected-runner-identity',
          optionalCollaborationOfficialRunnerIdentity,
          '--confirmed',
          'true',
        ],
      ]);
    },
  );

  test('catalog projection rejects executable directives', () {
    final catalog = _catalogJson();
    final workflows = catalog['workflows']! as Map<String, dynamic>;
    final deployment = workflows['localDeployment']! as Map<String, dynamic>;
    final features = deployment['features']! as List<dynamic>;
    (features.first as Map<String, dynamic>)['command'] = 'forbidden';

    expect(
      () => OptionalCollaborationWorkflowCatalog.fromJson(catalog),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          'optional_collaboration_executable_directive_rejected',
        ),
      ),
    );
  });
}

final class _RecordingRunner implements AgentCommandRunner {
  final List<List<String>> commands = [];

  @override
  Future<Map<String, dynamic>> runCli(List<String> args) async {
    commands.add(List.unmodifiable(args));
    final command = args.join(' ');
    if (command == 'collaboration status') return _statusJson();
    if (command.startsWith('collaboration enable')) {
      return _mutationJson('enabled', enabled: true, installed: false);
    }
    if (command.startsWith('collaboration runner-trust import')) {
      return _trustMutationJson('runner-trust-imported');
    }
    if (command.startsWith('collaboration install plan')) return _planJson();
    if (command.startsWith('collaboration install cancel')) {
      return {
        'ok': true,
        'status': 'cancelled',
        'planId': '00000000-0000-4000-8000-000000000000',
        'planConsumed': true,
        'idempotentReplay': false,
        'cleanupPending': false,
      };
    }
    if (command.startsWith('collaboration install apply')) {
      return _mutationJson(
        'installed',
        enabled: true,
        installed: true,
        plugin: _pluginJson(),
      );
    }
    if (command == 'collaboration workflow catalog') return _catalogJson();
    if (command.startsWith('collaboration disable')) {
      return _mutationJson('disabled', enabled: false, installed: true);
    }
    if (command.startsWith('collaboration uninstall')) {
      return _mutationJson('uninstalled', enabled: false, installed: false);
    }
    if (command.startsWith('collaboration runner-trust remove')) {
      return _trustMutationJson('runner-trust-removed');
    }
    throw StateError('unexpected_test_command');
  }

  @override
  Future<Map<String, dynamic>> runCliWithStdin(
    List<String> args,
    String stdinText,
  ) {
    throw UnsupportedError('not used');
  }

  @override
  Stream<Map<String, dynamic>> streamCliJsonLines(List<String> args) {
    return const Stream.empty();
  }

  @override
  Stream<Map<String, dynamic>> streamCliJsonLinesWithStdin(
    List<String> args,
    String stdinText,
  ) {
    return const Stream.empty();
  }
}

Map<String, dynamic> _statusJson() => {
  'capabilityEnabled': false,
  'pluginInstalled': false,
  'pluginLoaded': false,
  'loadPolicy': 'explicit-command-only',
};

Map<String, dynamic> _mutationJson(
  String status, {
  required bool enabled,
  required bool installed,
  Map<String, dynamic>? plugin,
}) => {
  'status': status,
  'capabilityEnabled': enabled,
  'pluginInstalled': installed,
  'pluginLoaded': false,
  'loadPolicy': 'explicit-command-only',
  'plugin': ?plugin,
};

Map<String, dynamic> _planJson() => {
  'planId': '00000000-0000-4000-8000-000000000000',
  'source': {
    'kind': 'github',
    'url': _sourceUrl,
    'ref': _commit,
    'pluginPath': 'plugin',
  },
  'plugin': {
    'pluginId': 'licomesh-collaboration',
    'displayName': 'LicoMesh Collaboration',
    'version': '1.0.0',
    'capabilities': ['local-deployment', 'mcp-install'],
  },
  'packageDigestSha256': _digest,
  'fileCount': 4,
  'totalBytes': 2048,
  'expiresAtEpochSeconds': 2000000000,
  'requiresDirectConfirmation': true,
  'runnerTrust': _runnerTrustJson(),
};

Map<String, dynamic> _pluginJson() => {
  'pluginId': 'licomesh-collaboration',
  'displayName': 'LicoMesh Collaboration',
  'version': '1.0.0',
  'packageDigestSha256': _digest,
  'signedPackageInventoryDigestSha256': _digest,
  'capabilities': ['local-deployment', 'mcp-install'],
  'sourceCommitOid': _commit,
  'runnerTrustKeyId': 'official-runner-key',
  'runnerTrustFingerprintSha256': _runnerFingerprint,
  'source': {'kind': 'github', 'url': _sourceUrl},
};

Map<String, dynamic> _runnerTrustJson() => {
  'keyId': 'official-runner-key',
  'fingerprintSha256': _runnerFingerprint,
  'sourceRepositoryUrl': _runnerRepository,
  'runnerIdentity': optionalCollaborationOfficialRunnerIdentity,
};

Map<String, dynamic> _trustMutationJson(String status) => {
  'ok': true,
  'status': status,
  'keyId': status == 'runner-trust-imported' ? 'official-runner-key' : null,
  'fingerprintSha256': _runnerFingerprint,
  'sourceRepositoryUrl': _runnerRepository,
  'runnerIdentity': optionalCollaborationOfficialRunnerIdentity,
  'idempotent': false,
};

Map<String, dynamic> _catalogJson() => {
  'pluginLoaded': true,
  'loadPolicy': 'explicit-command-only',
  'plugin': _pluginJson(),
  'workflows': {
    'localDeployment': {
      'schemaVersion': 'licoup.collaboration.local-deployment.v1',
      'manualOnly': true,
      'features': [
        {
          'id': 'server-core',
          'label': 'Server Core',
          'description': 'Local server component',
          'packagePath': 'payload/server-core',
        },
      ],
    },
    'mcpInstall': {
      'schemaVersion': 'licoup.collaboration.mcp-install.v2',
      'manualOnly': true,
      'requiresPerFileApproval': true,
      'outboundPolicy': 'direct-user-exact-scope-one-shot',
      'plugins': [
        {
          'id': 'selected-mcp',
          'label': 'Selected MCP',
          'description': 'Agent-specific MCP package',
          'packagePath': 'payload/mcp-selected',
          'endpoint': 'https://example.invalid/mcp',
        },
      ],
    },
  },
  'externalTransferPolicy': 'direct-exact-operation-approval-required',
};
