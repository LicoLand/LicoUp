import 'dart:convert';

import 'package:licoup/src/backend/features/settings/services/optional_collaboration_service.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/contracts/optional_collaboration_workflow_models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/optional_collaboration_test_fixtures.dart';

const _packageDigest =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _planDigest =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _fileDigest =
    'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
const _registrationFileDigest =
    'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd';
const _registrationContentDigest =
    'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';
const _registrationId = '00000000-0000-4000-8000-000000000010';
const _registrationDestination =
    'test-data/licoup-state/mcp-agent-registrations/cursor/$_registrationId.json';
const _outboundPolicy = 'direct-user-exact-scope-one-shot';
const _deploymentId = '00000000-0000-4000-8000-000000000020';

void main() {
  test(
    'local deployment uses fixed exact plan apply and cancel commands',
    () async {
      final runner = _WorkflowRunner();
      final service = OptionalCollaborationService(runner: runner);
      final plan = await service.planLocalDeployment(
        selectedFeatureIds: const ['server-core'],
        destination: 'test-data/licomesh-local',
      );
      await service.applyLocalDeployment(plan: plan, confirmed: true);
      await service.cancelWorkflow(plan: plan, confirmed: true);

      expect(runner.commands, [
        [
          'collaboration',
          'workflow',
          'local-deployment',
          'plan',
          '--request-origin',
          'direct-user',
          '--selected-feature-ids',
          '["server-core"]',
          '--destination',
          'test-data/licomesh-local',
          '--destination-confirmed',
          'true',
        ],
        [
          'collaboration',
          'workflow',
          'local-deployment',
          'apply',
          '--request-origin',
          'direct-user',
          '--selected-feature-ids',
          '["server-core"]',
          '--destination',
          'test-data/licomesh-local',
          '--destination-confirmed',
          'true',
          '--plan-id',
          plan.planId,
          '--expected-plan-digest-sha256',
          _planDigest,
          '--expected-package-digest-sha256',
          _packageDigest,
          '--confirmed',
          'true',
        ],
        [
          'collaboration',
          'workflow',
          'cancel',
          '--request-origin',
          'direct-user',
          '--plan-id',
          plan.planId,
          '--expected-plan-digest-sha256',
          _planDigest,
          '--expected-package-digest-sha256',
          _packageDigest,
          '--confirmed',
          'true',
        ],
      ]);
    },
  );

  test('local server lifecycle uses only fixed direct-user commands', () async {
    final runner = _WorkflowRunner();
    final service = OptionalCollaborationService(runner: runner);
    final servers = await service.loadLocalServerStatus();
    await service.startLocalServer(
      deploymentId: servers.single.deploymentId,
      confirmed: true,
    );
    await service.stopLocalServer(
      deploymentId: servers.single.deploymentId,
      confirmed: true,
    );
    await service.uninstallLocalServer(
      deploymentId: servers.single.deploymentId,
      expectedAssemblyManifestDigestSha256: _registrationFileDigest,
      confirmed: true,
    );

    expect(runner.commands, [
      ['collaboration', 'local-server', 'status'],
      [
        'collaboration',
        'local-server',
        'start',
        '--request-origin',
        'direct-user',
        '--deployment-id',
        _deploymentId,
        '--confirmed',
        'true',
      ],
      [
        'collaboration',
        'local-server',
        'stop',
        '--request-origin',
        'direct-user',
        '--deployment-id',
        _deploymentId,
        '--confirmed',
        'true',
      ],
      [
        'collaboration',
        'local-server',
        'uninstall',
        '--request-origin',
        'direct-user',
        '--deployment-id',
        _deploymentId,
        '--expected-assembly-manifest-digest-sha256',
        _registrationFileDigest,
        '--confirmed',
        'true',
      ],
    ]);
  });

  test(
    'MCP install binds exact agents and local destinations on apply',
    () async {
      final runner = _WorkflowRunner();
      final service = OptionalCollaborationService(runner: runner);
      const destination = OptionalCollaborationAgentDestination(
        agentId: 'cursor',
        installDestination: 'test-data/licoup-mcp',
      );
      final plan = await service.planMcpInstall(
        selectedPluginIds: const ['selected-mcp'],
        agentDestinations: const [destination],
      );
      await service.applyMcpInstall(plan: plan, confirmed: true);

      final exactDestinations = jsonEncode([destination.toConfirmedJson()]);
      expect(runner.commands, [
        [
          'collaboration',
          'workflow',
          'mcp-install',
          'plan',
          '--request-origin',
          'direct-user',
          '--selected-plugin-ids',
          '["selected-mcp"]',
          '--agent-destinations',
          exactDestinations,
        ],
        [
          'collaboration',
          'workflow',
          'mcp-install',
          'apply',
          '--request-origin',
          'direct-user',
          '--selected-plugin-ids',
          '["selected-mcp"]',
          '--agent-destinations',
          exactDestinations,
          '--plan-id',
          plan.planId,
          '--expected-plan-digest-sha256',
          _planDigest,
          '--expected-package-digest-sha256',
          _packageDigest,
          '--confirmed',
          'true',
        ],
      ]);
    },
  );
}

final class _WorkflowRunner implements AgentCommandRunner {
  final List<List<String>> commands = [];

  @override
  Future<Map<String, dynamic>> runCli(List<String> args) async {
    commands.add(List.unmodifiable(args));
    final command = args.take(4).join(' ');
    if (command == 'collaboration workflow local-deployment plan') {
      return _localPlanJson();
    }
    if (command == 'collaboration workflow local-deployment apply') {
      return _localApplyJson();
    }
    if (command == 'collaboration workflow mcp-install plan') {
      return _mcpPlanJson();
    }
    if (command == 'collaboration workflow mcp-install apply') {
      return _mcpApplyJson();
    }
    if (args.take(3).join(' ') == 'collaboration workflow cancel') {
      return _cancelJson();
    }
    if (args.take(3).join(' ') == 'collaboration local-server status') {
      return {
        'ok': true,
        'status': 'loaded',
        'servers': [_localServer()],
      };
    }
    if (args.take(3).join(' ') == 'collaboration local-server start') {
      return {
        'ok': true,
        'status': 'deployment-started',
        'server': _localServer(status: 'running'),
      };
    }
    if (args.take(3).join(' ') == 'collaboration local-server stop') {
      return {
        'ok': true,
        'status': 'deployment-stopped',
        'server': _localServer(),
      };
    }
    if (args.take(3).join(' ') == 'collaboration local-server uninstall') {
      return {
        'ok': true,
        'status': 'uninstalled',
        'deploymentId': _deploymentId,
        'assemblyManifestDigestSha256': _registrationFileDigest,
        'cleanupPending': false,
      };
    }
    throw StateError('unexpected_test_command');
  }

  @override
  Future<Map<String, dynamic>> runCliWithStdin(
    List<String> args,
    String stdinText,
  ) => throw UnsupportedError('not used');

  @override
  Stream<Map<String, dynamic>> streamCliJsonLines(List<String> args) =>
      const Stream.empty();

  @override
  Stream<Map<String, dynamic>> streamCliJsonLinesWithStdin(
    List<String> args,
    String stdinText,
  ) => const Stream.empty();
}

Map<String, dynamic> _localPlanJson() => {
  ..._planEnvelope('local-deployment'),
  'planId': '00000000-0000-4000-8000-000000000001',
  'selectedFeatureIds': ['server-core'],
  'selectedPluginIds': null,
  'destination': 'test-data/licomesh-local',
  'agents': <dynamic>[],
  'fileChanges': [_localFile()],
  'agentRegistrations': <dynamic>[],
  'assemblyPlan': _assemblyPlan(),
  'requiresPerFileApproval': false,
};

Map<String, dynamic> _localApplyJson() => {
  ..._applyEnvelope('local-deployment'),
  'planId': '00000000-0000-4000-8000-000000000001',
  'selectedFeatureIds': ['server-core'],
  'selectedPluginIds': null,
  'destination': 'test-data/licomesh-local',
  'agents': <dynamic>[],
  'fileChanges': [_localFile()],
  'agentRegistrations': <dynamic>[],
  'localServer': _localServer(),
  'requiresPerFileApproval': false,
};

Map<String, dynamic> _mcpPlanJson() => {
  ..._planEnvelope('mcp-install'),
  'planId': '00000000-0000-4000-8000-000000000002',
  'selectedFeatureIds': null,
  'selectedPluginIds': ['selected-mcp'],
  'destination': null,
  'agents': [_agent()],
  'fileChanges': [_mcpFile()],
  'agentRegistrations': [_registrationPlan()],
  'assemblyPlan': null,
  'requiresPerFileApproval': true,
};

Map<String, dynamic> _mcpApplyJson() => {
  ..._applyEnvelope('mcp-install'),
  'planId': '00000000-0000-4000-8000-000000000002',
  'selectedFeatureIds': null,
  'selectedPluginIds': ['selected-mcp'],
  'destination': null,
  'agents': [_agent()],
  'fileChanges': [_mcpFile()],
  'agentRegistrations': [
    {
      'agentId': 'cursor',
      'registrationId': _registrationId,
      'destination': _registrationDestination,
      'digestSha256': _registrationFileDigest,
      'registered': true,
    },
  ],
  'localServer': null,
  'requiresPerFileApproval': true,
};

Map<String, dynamic> _planEnvelope(String kind) => {
  'ok': true,
  'status': 'planned',
  'workflowKind': kind,
  'planDigestSha256': _planDigest,
  'packageDigestSha256': _packageDigest,
  'pluginId': 'licomesh-collaboration',
  'expiresAtEpochSeconds': 2000000000,
  'oneTime': true,
  'cancellable': true,
  'requiresDirectConfirmation': true,
  'pluginExecuted': false,
  'pluginCodeWillExecute': false,
  'assemblyAdapterWillExecute': kind == 'local-deployment',
  'vendorConfigurationModified': false,
  'agentRegistrationModified': false,
  'externalFileTransferAuthorized': false,
  'outboundPolicy': kind == 'mcp-install' ? _outboundPolicy : null,
};

Map<String, dynamic> _applyEnvelope(String kind) => {
  'ok': true,
  'status': kind == 'local-deployment' ? 'assembled' : 'applied',
  'workflowKind': kind,
  'planConsumed': true,
  'packageDigestSha256': _packageDigest,
  'pluginId': 'licomesh-collaboration',
  'pluginExecuted': false,
  'pluginCodeExecuted': false,
  'assemblyAdapterExecuted': kind == 'local-deployment',
  'vendorConfigurationModified': false,
  'agentRegistrationModified': kind == 'mcp-install',
  'externalFileTransferAuthorized': false,
  'outboundPolicy': kind == 'mcp-install' ? _outboundPolicy : null,
  'cleanupPending': false,
};

Map<String, dynamic> _assemblyPlan() => {
  'deploymentId': _deploymentId,
  'pluginId': 'licomesh-collaboration',
  'sourceUrl': 'https://github.com/example/licomesh-bundle.git',
  'serverVersion': '1.0.0',
  'packageDigestSha256': _packageDigest,
  'selectedComponentIds': ['server-core'],
  'destination': 'test-data/licomesh-local',
  'assemblyAdapterId': 'licoup-builtin-local-http-v1',
  'assemblyManifestDigestSha256': _registrationFileDigest,
  'assemblyManifestBytes': 512,
  'bindHost': '127.0.0.1',
  'port': 43121,
  ...optionalCollaborationTestRunnerBindings(
    digest: _packageDigest,
    planned: true,
  ),
  'loopbackOnly': true,
  'preflightPassed': true,
  'pluginCodeWillExecute': false,
  'externalFileTransferAuthorized': false,
};

Map<String, dynamic> _localServer({
  String status = 'assembled-awaiting-deployment',
}) => {
  'deploymentId': _deploymentId,
  'status': status,
  'sourceUrl': 'https://github.com/example/licomesh-bundle.git',
  'serverVersion': '1.0.0',
  'packageDigestSha256': _packageDigest,
  'selectedComponentIds': ['server-core'],
  'destination': 'test-data/licomesh-local',
  'assemblyAdapterId': 'licoup-builtin-local-http-v1',
  'assemblyManifestDigestSha256': _registrationFileDigest,
  'bindHost': '127.0.0.1',
  'port': 43121,
  ...optionalCollaborationTestRunnerBindings(
    digest: _packageDigest,
    planned: false,
    status: status,
  ),
  'loopbackOnly': true,
  'pluginCodeExecuted': false,
  'externalFileTransferAuthorized': false,
};

Map<String, dynamic> _localFile() => {
  'selectionId': 'server-core',
  'sourceRelativePath': 'payload/server-core/server',
  'destination': 'test-data/licomesh-local/server',
  'destinationRelativePath': 'server',
  'digestSha256': _fileDigest,
  'bytes': 128,
};

Map<String, dynamic> _mcpFile() => {
  'agentId': 'cursor',
  'selectionId': 'selected-mcp',
  'sourceRelativePath': 'payload/mcp-selected/server',
  'destination': 'test-data/licoup-mcp/selected-mcp/server',
  'destinationRelativePath': 'selected-mcp/server',
  'digestSha256': _fileDigest,
  'bytes': 128,
};

Map<String, dynamic> _agent() => {
  'agentId': 'cursor',
  'installDestination': 'test-data/licoup-mcp',
};

Map<String, dynamic> _registrationPlan() => {
  'agentId': 'cursor',
  'registrationId': _registrationId,
  'destination': _registrationDestination,
  'digestSha256': _registrationFileDigest,
  'registration': {
    'schemaVersion': 'licoup.mcp-agent-registration.v2',
    'registrationId': _registrationId,
    'registrationDigestSha256': _registrationContentDigest,
    'agentId': 'cursor',
    'collaborationPluginId': 'licomesh-collaboration',
    'packageDigestSha256': _packageDigest,
    'selectedPluginIds': ['selected-mcp'],
    'payloadRoots': [
      {'pluginId': 'selected-mcp', 'path': 'test-data/licoup-mcp/selected-mcp'},
    ],
    'payloadFiles': [
      {
        'pluginId': 'selected-mcp',
        'relativePath': 'selected-mcp/server',
        'digestSha256': _fileDigest,
        'bytes': 128,
      },
    ],
    'servers': [
      {
        'pluginId': 'selected-mcp',
        'transport': 'streamable-http',
        'endpoint': 'https://mcp.example.test/',
      },
    ],
    'bridgeKind': 'licoup-stdio-mcp-gate',
    'activationPolicy': 'disabled-authenticated-broker-unavailable',
    'automaticTriggersAllowed': false,
    'pluginExecutedDuringInstall': false,
    'externalFileTransferAuthorized': false,
    'outboundPolicy': _outboundPolicy,
    'requiresDirectUserConfirmation': true,
  },
};

Map<String, dynamic> _cancelJson() => {
  'ok': true,
  'status': 'cancelled',
  'workflowKind': 'local-deployment',
  'planId': '00000000-0000-4000-8000-000000000001',
  'planDigestSha256': _planDigest,
  'packageDigestSha256': _packageDigest,
  'pluginId': 'licomesh-collaboration',
  'planConsumed': true,
};
