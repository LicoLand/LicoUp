import 'package:licoup/src/application/features/settings/controller/optional_collaboration_controller.dart';
import 'package:licoup/src/contracts/optional_collaboration_gateway.dart';
import 'package:licoup/src/contracts/optional_collaboration_models.dart';
import 'package:licoup/src/contracts/optional_collaboration_local_server_models.dart';
import 'package:licoup/src/contracts/optional_collaboration_workflow_models.dart';
import 'package:flutter_test/flutter_test.dart';

const _digest =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
const _otherDigest =
    'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
const _commit = '0123456789abcdef0123456789abcdef01234567';
const _runnerPublicKey = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
const _runnerFingerprint =
    '66687aadf862bd776c8fc18b8e9f8e20089714856ee233b3902a591d0d5f2925';
const _runnerRepository = 'https://github.com/example/licomesh-runner.git';
const _runnerTrust = OptionalCollaborationRunnerTrust(
  keyId: 'official-runner-key',
  fingerprintSha256: _runnerFingerprint,
  sourceRepositoryUrl: _runnerRepository,
  runnerIdentity: optionalCollaborationOfficialRunnerIdentity,
);

void main() {
  test(
    'construction is inert and catalog loads only after explicit request',
    () async {
      final gateway = _FakeGateway(
        initialState: _installedState,
        catalog: _catalog,
      );
      final controller = OptionalCollaborationController(gateway: gateway);
      addTearDown(controller.dispose);

      expect(gateway.calls, isEmpty);
      expect(controller.statusLoaded, isFalse);
      expect(controller.catalogLoaded, isFalse);

      expect(await controller.loadStatus(), isTrue);
      expect(gateway.calls, ['status']);
      expect(controller.catalogLoaded, isFalse);

      expect(await controller.loadWorkflowCatalog(), isTrue);
      expect(gateway.calls, ['status', 'catalog']);
      expect(controller.catalogLoaded, isTrue);
    },
  );

  test(
    'enable and install require direct confirmation and exact plan digest',
    () async {
      final gateway = _FakeGateway(
        initialState: const OptionalCollaborationRuntimeState.disabled(),
        plan: _plan,
      );
      final controller = OptionalCollaborationController(gateway: gateway);
      addTearDown(controller.dispose);

      expect(await controller.enable(confirmed: false), isFalse);
      expect(gateway.calls, isEmpty);
      expect(await controller.enable(confirmed: true), isTrue);
      expect(gateway.calls, ['enable:true']);

      expect(
        await controller.importRunnerTrust(
          keyId: _runnerTrust.keyId,
          publicKeyBase64url: _runnerPublicKey,
          sourceRepositoryUrl: _runnerRepository,
          expectedFingerprintSha256: _runnerFingerprint,
          confirmed: true,
        ),
        isTrue,
      );

      expect(
        await controller.planInstall(githubUrl: 'https://example.com/plugin'),
        isFalse,
      );
      expect(gateway.calls, ['enable:true', 'trust-import:true']);

      expect(
        await controller.planInstall(
          githubUrl: 'https://github.com/example/collaboration-plugin',
          gitRef: _commit,
          confirmed: true,
        ),
        isTrue,
      );
      expect(controller.installPlan?.packageDigestSha256, _digest);

      expect(await controller.applyInstall(confirmed: false), isFalse);
      expect(gateway.appliedPlanId, isEmpty);
      expect(await controller.applyInstall(confirmed: true), isTrue);
      expect(gateway.appliedPlanId, _plan.planId);
      expect(gateway.appliedDigest, _digest);
      expect(controller.catalogLoaded, isFalse);
    },
  );

  test('disable and uninstall remain separate confirmed actions', () async {
    final gateway = _FakeGateway(initialState: _installedState);
    var purgeCount = 0;
    final controller = OptionalCollaborationController(
      gateway: gateway,
      onCatalogPurge: () async => purgeCount += 1,
    );
    addTearDown(controller.dispose);
    await controller.loadStatus();

    expect(await controller.disable(confirmed: false), isFalse);
    expect(gateway.calls, ['status']);
    expect(await controller.disable(confirmed: true), isTrue);
    expect(gateway.calls, ['status', 'disable:true']);
    expect(purgeCount, 1);

    expect(await controller.uninstall(confirmed: false), isFalse);
    expect(gateway.uninstallDigest, isEmpty);
    expect(await controller.uninstall(confirmed: true), isTrue);
    expect(gateway.uninstallDigest, _digest);
    expect(controller.state?.pluginInstalled, isFalse);
    expect(purgeCount, 2);
  });

  test('install plan cancellation requires a separate confirmation', () async {
    final gateway = _FakeGateway(initialState: _enabledState, plan: _plan);
    final controller = OptionalCollaborationController(gateway: gateway);
    addTearDown(controller.dispose);
    await controller.loadStatus();
    expect(
      await controller.planInstall(
        githubUrl: _plan.sourceUrl,
        gitRef: _commit,
        confirmed: true,
      ),
      isTrue,
    );

    expect(await controller.cancelInstall(confirmed: false), isFalse);
    expect(gateway.calls, isNot(contains('install-cancel:true')));
    expect(await controller.cancelInstall(confirmed: true), isTrue);
    expect(gateway.calls, contains('install-cancel:true'));
    expect(controller.installPlan, isNull);
  });

  test('install apply and catalog reject plugin identity drift', () async {
    final applyGateway = _FakeGateway(
      initialState: _enabledState,
      plan: _plan,
      appliedPlugin: _driftPlugin,
    );
    final applyController = OptionalCollaborationController(
      gateway: applyGateway,
    );
    addTearDown(applyController.dispose);
    await applyController.loadStatus();
    await applyController.planInstall(
      githubUrl: _plan.sourceUrl,
      gitRef: _commit,
      confirmed: true,
    );
    expect(await applyController.applyInstall(confirmed: true), isFalse);
    expect(applyController.state?.pluginInstalled, isFalse);

    final catalogGateway = _FakeGateway(
      initialState: _installedState,
      catalog: _driftCatalog,
    );
    final catalogController = OptionalCollaborationController(
      gateway: catalogGateway,
    );
    addTearDown(catalogController.dispose);
    await catalogController.loadStatus();
    expect(await catalogController.loadWorkflowCatalog(), isFalse);
    expect(catalogController.workflowCatalog, isNull);
  });
}

final class _FakeGateway implements OptionalCollaborationGateway {
  _FakeGateway({
    required this.initialState,
    this.plan = _plan,
    this.catalog = _catalog,
    this.appliedPlugin = _plugin,
  });

  final OptionalCollaborationRuntimeState initialState;
  final OptionalCollaborationInstallPlan plan;
  final OptionalCollaborationWorkflowCatalog catalog;
  final OptionalCollaborationPlugin appliedPlugin;
  final List<String> calls = [];
  String appliedPlanId = '';
  String appliedDigest = '';
  String uninstallDigest = '';

  @override
  Future<OptionalCollaborationRuntimeState> status() async {
    calls.add('status');
    return initialState;
  }

  @override
  Future<OptionalCollaborationMutation> enable({
    required bool confirmed,
  }) async {
    calls.add('enable:$confirmed');
    return const OptionalCollaborationMutation(
      status: 'enabled',
      capabilityEnabled: true,
      pluginInstalled: false,
      pluginLoaded: false,
      loadPolicy: 'explicit-command-only',
    );
  }

  @override
  Future<OptionalCollaborationRunnerTrustMutation> importRunnerTrust({
    required String keyId,
    required String publicKeyBase64url,
    required String sourceRepositoryUrl,
    required String runnerIdentity,
    required String expectedFingerprintSha256,
    required bool confirmed,
  }) async {
    calls.add('trust-import:$confirmed');
    return OptionalCollaborationRunnerTrustMutation(
      status: 'runner-trust-imported',
      fingerprintSha256: expectedFingerprintSha256,
      keyId: keyId,
      idempotent: false,
      sourceRepositoryUrl: sourceRepositoryUrl,
      runnerIdentity: runnerIdentity,
    );
  }

  @override
  Future<OptionalCollaborationRunnerTrustMutation> removeRunnerTrust({
    required String expectedFingerprintSha256,
    required String expectedSourceRepositoryUrl,
    required String expectedRunnerIdentity,
    required bool confirmed,
  }) => throw UnsupportedError('not used');

  @override
  Future<OptionalCollaborationInstallPlan> planInstall({
    required String githubUrl,
    String gitRef = '',
    String pluginPath = '',
    required bool confirmed,
  }) async {
    calls.add('plan:$githubUrl:$gitRef:$pluginPath:$confirmed');
    return plan;
  }

  @override
  Future<OptionalCollaborationInstallCancellation> cancelInstall({
    required OptionalCollaborationInstallPlan plan,
    required bool confirmed,
  }) async {
    calls.add('install-cancel:$confirmed');
    return OptionalCollaborationInstallCancellation(
      planId: plan.planId,
      cleanupPending: false,
      idempotentReplay: false,
    );
  }

  @override
  Future<OptionalCollaborationMutation> applyInstall({
    required String planId,
    required String expectedDigestSha256,
    required bool confirmed,
  }) async {
    calls.add('apply:$confirmed');
    appliedPlanId = planId;
    appliedDigest = expectedDigestSha256;
    return OptionalCollaborationMutation(
      status: 'installed',
      capabilityEnabled: true,
      pluginInstalled: true,
      pluginLoaded: false,
      loadPolicy: 'explicit-command-only',
      plugin: appliedPlugin,
    );
  }

  @override
  Future<OptionalCollaborationWorkflowCatalog> loadWorkflowCatalog() async {
    calls.add('catalog');
    return catalog;
  }

  @override
  Future<OptionalCollaborationWorkflowApplyResult> applyLocalDeployment({
    required OptionalCollaborationWorkflowPlan plan,
    required bool confirmed,
  }) => throw UnsupportedError('not used');

  @override
  Future<OptionalCollaborationWorkflowApplyResult> applyMcpInstall({
    required OptionalCollaborationWorkflowPlan plan,
    required bool confirmed,
  }) => throw UnsupportedError('not used');

  @override
  Future<OptionalCollaborationWorkflowCancellation> cancelWorkflow({
    required OptionalCollaborationWorkflowPlan plan,
    required bool confirmed,
  }) => throw UnsupportedError('not used');

  @override
  Future<OptionalCollaborationWorkflowPlan> planLocalDeployment({
    required List<String> selectedFeatureIds,
    required String destination,
  }) => throw UnsupportedError('not used');

  @override
  Future<OptionalCollaborationWorkflowPlan> planMcpInstall({
    required List<String> selectedPluginIds,
    required List<OptionalCollaborationAgentDestination> agentDestinations,
  }) => throw UnsupportedError('not used');

  @override
  Future<List<OptionalLocalServerState>> loadLocalServerStatus() =>
      throw UnsupportedError('not used');

  @override
  Future<OptionalLocalServerState> startLocalServer({
    required String deploymentId,
    required bool confirmed,
  }) => throw UnsupportedError('not used');

  @override
  Future<OptionalLocalServerState> stopLocalServer({
    required String deploymentId,
    required bool confirmed,
  }) => throw UnsupportedError('not used');

  @override
  Future<OptionalLocalServerUninstallResult> uninstallLocalServer({
    required String deploymentId,
    required String expectedAssemblyManifestDigestSha256,
    required bool confirmed,
  }) => throw UnsupportedError('not used');

  @override
  Future<OptionalCollaborationMutation> disable({
    required bool confirmed,
  }) async {
    calls.add('disable:$confirmed');
    return const OptionalCollaborationMutation(
      status: 'disabled',
      capabilityEnabled: false,
      pluginInstalled: true,
      pluginLoaded: false,
      loadPolicy: 'explicit-command-only',
    );
  }

  @override
  Future<OptionalCollaborationMutation> uninstall({
    required String expectedDigestSha256,
    required bool confirmed,
  }) async {
    calls.add('uninstall:$confirmed');
    uninstallDigest = expectedDigestSha256;
    return const OptionalCollaborationMutation(
      status: 'uninstalled',
      capabilityEnabled: false,
      pluginInstalled: false,
      pluginLoaded: false,
      loadPolicy: 'explicit-command-only',
    );
  }
}

const _plugin = OptionalCollaborationPlugin(
  id: 'licomesh-collaboration',
  displayName: 'LicoMesh Collaboration',
  version: '1.0.0',
  packageDigestSha256: _digest,
  capabilities: ['local-deployment', 'mcp-install'],
  sourceUrl: 'https://github.com/example/collaboration-plugin.git',
  sourceCommitOid: _commit,
  signedPackageInventoryDigestSha256: _digest,
  runnerTrustKeyId: 'official-runner-key',
  runnerTrustFingerprintSha256: _runnerFingerprint,
);

const _driftPlugin = OptionalCollaborationPlugin(
  id: 'licomesh-collaboration',
  displayName: 'LicoMesh Collaboration',
  version: '1.0.0',
  packageDigestSha256: _otherDigest,
  capabilities: ['local-deployment', 'mcp-install'],
  sourceUrl: 'https://github.com/example/collaboration-plugin.git',
  sourceCommitOid: _commit,
  signedPackageInventoryDigestSha256: _otherDigest,
  runnerTrustKeyId: 'official-runner-key',
  runnerTrustFingerprintSha256: _runnerFingerprint,
);

const _installedState = OptionalCollaborationRuntimeState(
  capabilityEnabled: true,
  pluginInstalled: true,
  pluginLoaded: false,
  loadPolicy: 'explicit-command-only',
  plugin: _plugin,
  runnerTrust: _runnerTrust,
);

const _enabledState = OptionalCollaborationRuntimeState(
  capabilityEnabled: true,
  pluginInstalled: false,
  pluginLoaded: false,
  loadPolicy: 'explicit-command-only',
  runnerTrust: _runnerTrust,
);

const _plan = OptionalCollaborationInstallPlan(
  planId: '00000000-0000-4000-8000-000000000000',
  sourceUrl: 'https://github.com/example/collaboration-plugin.git',
  sourceRef: _commit,
  pluginPath: '',
  plugin: OptionalCollaborationPluginSummary(
    id: 'licomesh-collaboration',
    displayName: 'LicoMesh Collaboration',
    version: '1.0.0',
    capabilities: ['local-deployment', 'mcp-install'],
  ),
  packageDigestSha256: _digest,
  fileCount: 4,
  totalBytes: 2048,
  expiresAtEpochSeconds: 2000000000,
  requiresDirectConfirmation: true,
  runnerTrust: _runnerTrust,
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

const _driftCatalog = OptionalCollaborationWorkflowCatalog(
  plugin: _driftPlugin,
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
