import 'package:licoup/src/application/features/settings/controller/optional_collaboration_workflow_controller.dart';
import 'package:licoup/src/contracts/optional_collaboration_gateway.dart';
import 'package:licoup/src/contracts/optional_collaboration_models.dart';
import 'package:licoup/src/contracts/optional_collaboration_local_server_models.dart';
import 'package:licoup/src/contracts/optional_collaboration_workflow_models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/optional_collaboration_test_fixtures.dart';

const _packageDigest =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _planDigest =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _fileDigest =
    'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
const _registrationDigest =
    'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd';
const _deploymentId = '00000000-0000-4000-8000-000000000020';

void main() {
  test(
    'local deployment requires catalog selection and exact confirmation',
    () async {
      final gateway = _WorkflowGateway();
      final controller = OptionalCollaborationWorkflowController(
        gateway: gateway,
      );
      addTearDown(controller.dispose);
      controller.replaceCatalog(_catalog);

      expect(
        await controller.planLocalDeployment(
          selectedFeatureIds: ['unknown'],
          destination: '/test-data/licomesh-local',
        ),
        isFalse,
      );
      expect(gateway.calls, isEmpty);

      expect(
        await controller.planLocalDeployment(
          selectedFeatureIds: ['server-core'],
          destination: '/test-data/licomesh-local',
        ),
        isTrue,
      );
      expect(controller.localDeploymentPlan?.selectedIds, ['server-core']);
      expect(await controller.applyLocalDeployment(confirmed: false), isFalse);
      expect(gateway.calls, ['local-plan']);

      expect(await controller.applyLocalDeployment(confirmed: true), isTrue);
      expect(gateway.calls, ['local-plan', 'local-apply:true']);
      expect(controller.localDeploymentPlan, isNull);
      expect(
        controller.lastApplyResult?.plan.destination,
        '/test-data/licomesh-local',
      );
    },
  );

  test(
    'assembled local server has separate start stop and uninstall approvals',
    () async {
      final gateway = _WorkflowGateway();
      final controller = OptionalCollaborationWorkflowController(
        gateway: gateway,
      );
      addTearDown(controller.dispose);
      controller.replaceCatalog(_catalog);
      await controller.planLocalDeployment(
        selectedFeatureIds: const ['server-core'],
        destination: '/test-data/licomesh-local',
      );
      await controller.applyLocalDeployment(confirmed: true);
      expect(controller.localServers.single.isStopped, isTrue);

      expect(
        await controller.startLocalServer(_deploymentId, confirmed: false),
        isFalse,
      );
      expect(
        await controller.startLocalServer(_deploymentId, confirmed: true),
        isTrue,
      );
      expect(controller.localServers.single.isRunning, isTrue);
      expect(
        await controller.stopLocalServer(_deploymentId, confirmed: true),
        isTrue,
      );
      expect(controller.localServers.single.isStopped, isTrue);
      expect(
        await controller.uninstallLocalServer(_deploymentId, confirmed: true),
        isTrue,
      );
      expect(controller.localServers, isEmpty);
      expect(gateway.calls, [
        'local-plan',
        'local-apply:true',
        'server-start:true',
        'server-stop:true',
        'server-uninstall:true',
      ]);
    },
  );

  test(
    'MCP plan sorts agents and cancellation consumes the exact plan',
    () async {
      final gateway = _WorkflowGateway();
      final controller = OptionalCollaborationWorkflowController(
        gateway: gateway,
      );
      addTearDown(controller.dispose);
      controller.replaceCatalog(_catalog);

      expect(
        await controller.planMcpInstall(
          selectedPluginIds: ['selected-mcp'],
          agentDestinations: const [
            OptionalCollaborationAgentDestination(
              agentId: 'cursor',
              installDestination: '/test-data/cursor-mcp',
            ),
            OptionalCollaborationAgentDestination(
              agentId: 'hermes',
              installDestination: '/test-data/hermes-mcp',
            ),
          ],
        ),
        isTrue,
      );
      expect(controller.mcpInstallPlan?.agents.map((agent) => agent.agentId), [
        'cursor',
        'hermes',
      ]);
      expect(
        await controller.cancel(
          OptionalCollaborationWorkflowKind.mcpInstall,
          confirmed: false,
        ),
        isFalse,
      );
      expect(gateway.calls, ['mcp-plan']);

      expect(
        await controller.cancel(
          OptionalCollaborationWorkflowKind.mcpInstall,
          confirmed: true,
        ),
        isTrue,
      );
      expect(gateway.calls, ['mcp-plan', 'cancel:true']);
      expect(controller.mcpInstallPlan, isNull);
    },
  );

  test('overlapping MCP destinations fail before the native gateway', () async {
    final gateway = _WorkflowGateway();
    final controller = OptionalCollaborationWorkflowController(
      gateway: gateway,
    );
    addTearDown(controller.dispose);
    controller.replaceCatalog(_catalog);

    expect(
      await controller.planMcpInstall(
        selectedPluginIds: ['selected-mcp'],
        agentDestinations: const [
          OptionalCollaborationAgentDestination(
            agentId: 'cursor',
            installDestination: '/test-data/cursor',
          ),
          OptionalCollaborationAgentDestination(
            agentId: 'hermes',
            installDestination: '/test-data/cursor/hermes',
          ),
        ],
      ),
      isFalse,
    );
    expect(gateway.calls, isEmpty);
  });
}

final class _WorkflowGateway implements OptionalCollaborationGateway {
  final List<String> calls = [];

  @override
  Future<OptionalCollaborationWorkflowPlan> planLocalDeployment({
    required List<String> selectedFeatureIds,
    required String destination,
  }) async {
    calls.add('local-plan');
    return OptionalCollaborationWorkflowPlan.fromJson(
      _localPlanJson(selectedFeatureIds, destination),
    );
  }

  @override
  Future<OptionalCollaborationWorkflowApplyResult> applyLocalDeployment({
    required OptionalCollaborationWorkflowPlan plan,
    required bool confirmed,
  }) async {
    calls.add('local-apply:$confirmed');
    return OptionalCollaborationWorkflowApplyResult.fromJson(
      _applyJson(plan),
      expectedPlan: plan,
    );
  }

  @override
  Future<OptionalCollaborationWorkflowPlan> planMcpInstall({
    required List<String> selectedPluginIds,
    required List<OptionalCollaborationAgentDestination> agentDestinations,
  }) async {
    calls.add('mcp-plan');
    return OptionalCollaborationWorkflowPlan.fromJson(
      _mcpPlanJson(selectedPluginIds, agentDestinations),
    );
  }

  @override
  Future<OptionalCollaborationWorkflowApplyResult> applyMcpInstall({
    required OptionalCollaborationWorkflowPlan plan,
    required bool confirmed,
  }) async {
    calls.add('mcp-apply:$confirmed');
    return OptionalCollaborationWorkflowApplyResult.fromJson(
      _applyJson(plan),
      expectedPlan: plan,
    );
  }

  @override
  Future<OptionalCollaborationWorkflowCancellation> cancelWorkflow({
    required OptionalCollaborationWorkflowPlan plan,
    required bool confirmed,
  }) async {
    calls.add('cancel:$confirmed');
    return OptionalCollaborationWorkflowCancellation.fromJson({
      'ok': true,
      'status': 'cancelled',
      'workflowKind': plan.kind.wireName,
      'planId': plan.planId,
      'planDigestSha256': plan.planDigestSha256,
      'packageDigestSha256': plan.packageDigestSha256,
      'pluginId': plan.pluginId,
      'planConsumed': true,
    }, expectedPlan: plan);
  }

  @override
  Future<List<OptionalLocalServerState>> loadLocalServerStatus() async {
    calls.add('server-status');
    return [_localServerState()];
  }

  @override
  Future<OptionalLocalServerState> startLocalServer({
    required String deploymentId,
    required bool confirmed,
  }) async {
    calls.add('server-start:$confirmed');
    return _localServerState(status: 'running');
  }

  @override
  Future<OptionalLocalServerState> stopLocalServer({
    required String deploymentId,
    required bool confirmed,
  }) async {
    calls.add('server-stop:$confirmed');
    return _localServerState();
  }

  @override
  Future<OptionalLocalServerUninstallResult> uninstallLocalServer({
    required String deploymentId,
    required String expectedAssemblyManifestDigestSha256,
    required bool confirmed,
  }) async {
    calls.add('server-uninstall:$confirmed');
    return const OptionalLocalServerUninstallResult(
      deploymentId: _deploymentId,
      assemblyManifestDigestSha256: _registrationDigest,
      cleanupPending: false,
    );
  }

  @override
  Future<OptionalCollaborationMutation> applyInstall({
    required String planId,
    required String expectedDigestSha256,
    required bool confirmed,
  }) => throw UnsupportedError('not used');

  @override
  Future<OptionalCollaborationInstallCancellation> cancelInstall({
    required OptionalCollaborationInstallPlan plan,
    required bool confirmed,
  }) => throw UnsupportedError('not used');

  @override
  Future<OptionalCollaborationMutation> disable({required bool confirmed}) =>
      throw UnsupportedError('not used');

  @override
  Future<OptionalCollaborationMutation> enable({required bool confirmed}) =>
      throw UnsupportedError('not used');

  @override
  Future<OptionalCollaborationRunnerTrustMutation> importRunnerTrust({
    required String keyId,
    required String publicKeyBase64url,
    required String sourceRepositoryUrl,
    required String runnerIdentity,
    required String expectedFingerprintSha256,
    required bool confirmed,
  }) => throw UnsupportedError('not used');

  @override
  Future<OptionalCollaborationRunnerTrustMutation> removeRunnerTrust({
    required String expectedFingerprintSha256,
    required String expectedSourceRepositoryUrl,
    required String expectedRunnerIdentity,
    required bool confirmed,
  }) => throw UnsupportedError('not used');

  @override
  Future<OptionalCollaborationWorkflowCatalog> loadWorkflowCatalog() =>
      throw UnsupportedError('not used');

  @override
  Future<OptionalCollaborationInstallPlan> planInstall({
    required String githubUrl,
    String gitRef = '',
    String pluginPath = '',
    required bool confirmed,
  }) => throw UnsupportedError('not used');

  @override
  Future<OptionalCollaborationRuntimeState> status() =>
      throw UnsupportedError('not used');

  @override
  Future<OptionalCollaborationMutation> uninstall({
    required String expectedDigestSha256,
    required bool confirmed,
  }) => throw UnsupportedError('not used');
}

Map<String, dynamic> _localPlanJson(
  List<String> selectedIds,
  String destination,
) => {
  ..._planEnvelope('local-deployment'),
  'planId': '00000000-0000-4000-8000-000000000001',
  'selectedFeatureIds': selectedIds,
  'selectedPluginIds': null,
  'destination': destination,
  'agents': <dynamic>[],
  'fileChanges': [
    {
      'selectionId': selectedIds.single,
      'sourceRelativePath': 'payload/server-core/server',
      'destination': '$destination/server',
      'destinationRelativePath': 'server',
      'digestSha256': _fileDigest,
      'bytes': 128,
    },
  ],
  'agentRegistrations': <dynamic>[],
  'assemblyPlan': _assemblyPlan(destination, selectedIds),
  'requiresPerFileApproval': false,
};

Map<String, dynamic> _mcpPlanJson(
  List<String> selectedIds,
  List<OptionalCollaborationAgentDestination> destinations,
) => {
  ..._planEnvelope('mcp-install'),
  'planId': '00000000-0000-4000-8000-000000000002',
  'selectedFeatureIds': null,
  'selectedPluginIds': selectedIds,
  'destination': null,
  'agents': [
    for (final destination in destinations)
      {
        'agentId': destination.agentId,
        'installDestination': destination.installDestination,
      },
  ],
  'fileChanges': [
    for (final destination in destinations)
      {
        'agentId': destination.agentId,
        'selectionId': selectedIds.single,
        'sourceRelativePath': 'payload/mcp-selected/server',
        'destination': '${destination.installDestination}/selected-mcp/server',
        'destinationRelativePath': 'selected-mcp/server',
        'digestSha256': _fileDigest,
        'bytes': 128,
      },
  ],
  'agentRegistrations': [
    for (var index = 0; index < destinations.length; index += 1)
      _registrationPlan(destinations[index], selectedIds, index),
  ],
  'assemblyPlan': null,
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
  'outboundPolicy': kind == 'mcp-install'
      ? 'direct-user-exact-scope-one-shot'
      : null,
};

Map<String, dynamic> _applyJson(OptionalCollaborationWorkflowPlan plan) => {
  'ok': true,
  'status': plan.kind == OptionalCollaborationWorkflowKind.localDeployment
      ? 'assembled'
      : 'applied',
  'workflowKind': plan.kind.wireName,
  'planId': plan.planId,
  'planConsumed': true,
  'packageDigestSha256': plan.packageDigestSha256,
  'pluginId': plan.pluginId,
  'selectedFeatureIds':
      plan.kind == OptionalCollaborationWorkflowKind.localDeployment
      ? plan.selectedIds
      : null,
  'selectedPluginIds': plan.kind == OptionalCollaborationWorkflowKind.mcpInstall
      ? plan.selectedIds
      : null,
  'destination': plan.destination.isEmpty ? null : plan.destination,
  'agents': [
    for (final agent in plan.agents)
      {
        'agentId': agent.agentId,
        'installDestination': agent.installDestination,
      },
  ],
  'fileChanges': [
    for (final change in plan.fileChanges)
      {
        if (change.agentId.isNotEmpty) 'agentId': change.agentId,
        'selectionId': change.selectionId,
        'sourceRelativePath': change.sourceRelativePath,
        'destination': change.destination,
        'destinationRelativePath': change.destinationRelativePath,
        'digestSha256': change.digestSha256,
        'bytes': change.bytes,
      },
  ],
  'agentRegistrations': [
    for (final registration in plan.agentRegistrations)
      {
        'agentId': registration.agentId,
        'registrationId': registration.registrationId,
        'destination': registration.destination,
        'digestSha256': registration.digestSha256,
        'registered': true,
      },
  ],
  'localServer': plan.kind == OptionalCollaborationWorkflowKind.localDeployment
      ? _localServerJson(plan.destination, plan.selectedIds)
      : null,
  'pluginExecuted': false,
  'pluginCodeExecuted': false,
  'assemblyAdapterExecuted':
      plan.kind == OptionalCollaborationWorkflowKind.localDeployment,
  'vendorConfigurationModified': false,
  'agentRegistrationModified':
      plan.kind == OptionalCollaborationWorkflowKind.mcpInstall,
  'externalFileTransferAuthorized': false,
  'outboundPolicy': plan.kind == OptionalCollaborationWorkflowKind.mcpInstall
      ? 'direct-user-exact-scope-one-shot'
      : null,
  'requiresPerFileApproval':
      plan.kind == OptionalCollaborationWorkflowKind.mcpInstall,
  'cleanupPending': false,
};

Map<String, dynamic> _assemblyPlan(
  String destination,
  List<String> selectedIds,
) => {
  'deploymentId': _deploymentId,
  'pluginId': 'licomesh-collaboration',
  'sourceUrl': 'https://github.com/example/licomesh-bundle.git',
  'serverVersion': '1.0.0',
  'packageDigestSha256': _packageDigest,
  'selectedComponentIds': selectedIds,
  'destination': destination,
  'assemblyAdapterId': 'licoup-builtin-local-http-v1',
  'assemblyManifestDigestSha256': _registrationDigest,
  'assemblyManifestBytes': 512,
  'bindHost': '127.0.0.1',
  'port': 43121,
  ...optionalCollaborationTestRunnerBindings(
    digest: _registrationDigest,
    planned: true,
    signedInventoryDigest: _packageDigest,
  ),
  'loopbackOnly': true,
  'preflightPassed': true,
  'pluginCodeWillExecute': false,
  'externalFileTransferAuthorized': false,
};

Map<String, dynamic> _localServerJson(
  String destination,
  List<String> selectedIds, {
  String status = 'assembled-awaiting-deployment',
}) => {
  'deploymentId': _deploymentId,
  'status': status,
  'sourceUrl': 'https://github.com/example/licomesh-bundle.git',
  'serverVersion': '1.0.0',
  'packageDigestSha256': _packageDigest,
  'selectedComponentIds': selectedIds,
  'destination': destination,
  'assemblyAdapterId': 'licoup-builtin-local-http-v1',
  'assemblyManifestDigestSha256': _registrationDigest,
  'bindHost': '127.0.0.1',
  'port': 43121,
  ...optionalCollaborationTestRunnerBindings(
    digest: _registrationDigest,
    planned: false,
    status: status,
    signedInventoryDigest: _packageDigest,
  ),
  'loopbackOnly': true,
  'pluginCodeExecuted': false,
  'externalFileTransferAuthorized': false,
};

OptionalLocalServerState _localServerState({
  String status = 'assembled-awaiting-deployment',
}) => OptionalLocalServerState.fromJson(
  _localServerJson('/test-data/licomesh-local', const [
    'server-core',
  ], status: status),
);

Map<String, dynamic> _registrationPlan(
  OptionalCollaborationAgentDestination destination,
  List<String> selectedIds,
  int index,
) {
  final registrationId =
      '00000000-0000-4000-8000-${(index + 10).toString().padLeft(12, '0')}';
  final registrationDestination =
      '/test-data/licoup-private/${destination.agentId}/$registrationId.json';
  return {
    'agentId': destination.agentId,
    'registrationId': registrationId,
    'destination': registrationDestination,
    'digestSha256': _registrationDigest,
    'registration': {
      'schemaVersion': 'licoup.mcp-agent-registration.v2',
      'registrationId': registrationId,
      'registrationDigestSha256': _registrationDigest,
      'agentId': destination.agentId,
      'collaborationPluginId': 'licomesh-collaboration',
      'packageDigestSha256': _packageDigest,
      'selectedPluginIds': selectedIds,
      'payloadRoots': [
        for (final selectedId in selectedIds)
          {
            'pluginId': selectedId,
            'path': '${destination.installDestination}/$selectedId',
          },
      ],
      'payloadFiles': <dynamic>[],
      'servers': <dynamic>[],
      'bridgeKind': 'licoup-stdio-mcp-gate',
      'activationPolicy': 'disabled-authenticated-broker-unavailable',
      'automaticTriggersAllowed': false,
      'pluginExecutedDuringInstall': false,
      'externalFileTransferAuthorized': false,
      'outboundPolicy': 'direct-user-exact-scope-one-shot',
      'requiresDirectUserConfirmation': true,
    },
  };
}

const _plugin = OptionalCollaborationPlugin(
  id: 'licomesh-collaboration',
  displayName: 'LicoMesh Collaboration',
  version: '1.0.0',
  packageDigestSha256: _packageDigest,
  capabilities: ['local-deployment', 'mcp-install'],
  sourceUrl: 'https://github.com/example/collaboration-plugin.git',
  sourceCommitOid: optionalCollaborationTestCommit,
  signedPackageInventoryDigestSha256: _packageDigest,
  runnerTrustKeyId: optionalCollaborationTestRunnerKeyId,
  runnerTrustFingerprintSha256: optionalCollaborationTestRunnerFingerprint,
);

const _catalog = OptionalCollaborationWorkflowCatalog(
  plugin: _plugin,
  localDeploymentChoices: [
    OptionalCollaborationWorkflowChoice(
      id: 'server-core',
      label: 'Server Core',
      description: 'Local server component',
      packagePath: 'payload/server-core',
    ),
  ],
  mcpInstallChoices: [
    OptionalCollaborationWorkflowChoice(
      id: 'selected-mcp',
      label: 'Selected MCP',
      description: 'Agent-specific MCP package',
      packagePath: 'payload/mcp-selected',
    ),
  ],
  requiresPerFileApproval: true,
  externalTransferPolicy: 'direct-exact-operation-approval-required',
);
