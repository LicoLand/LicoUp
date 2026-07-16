import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_client/src/application/features/settings/controller/optional_collaboration_controller.dart';
import 'package:flutter_client/src/contracts/optional_collaboration_gateway.dart';
import 'package:flutter_client/src/contracts/optional_collaboration_models.dart';
import 'package:flutter_client/src/contracts/optional_collaboration_local_server_models.dart';
import 'package:flutter_client/src/contracts/optional_collaboration_workflow_models.dart';
import 'package:flutter_client/src/frontend/features/settings/ui/optional_collaboration_settings.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/optional_collaboration_test_fixtures.dart';

const _digest =
    'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc';
const _workflowPlanDigest =
    'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd';
const _workflowFileDigest =
    'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee';
const _workflowRegistrationDigest =
    'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff';
const _deploymentId = '00000000-0000-4000-8000-000000000020';

void main() {
  testWidgets(
    'settings stays inert until status and catalog buttons are clicked',
    (tester) async {
      final gateway = _WidgetGateway(statusState: _installedState);
      final controller = OptionalCollaborationController(gateway: gateway);
      addTearDown(controller.dispose);
      await _pumpSettings(tester, controller);

      expect(gateway.calls, isEmpty);
      expect(find.text('Optional Collaboration'), findsOneWidget);
      expect(
        find.textContaining('Disabled, unqueried, and unloaded'),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('collaboration-deployment-workflow-section')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('collaboration-mcp-install-workflow-section')),
        findsNothing,
      );

      await tester.tap(find.byKey(const Key('collaboration-load-status')));
      await tester.pumpAndSettle();
      expect(gateway.calls, ['status']);
      expect(find.textContaining('Catalog: not loaded'), findsOneWidget);
      expect(find.textContaining(_digest), findsWidgets);
      expect(
        find.byKey(const Key('collaboration-deployment-workflow-section')),
        findsNothing,
      );

      final catalogButton = find.byKey(const Key('collaboration-load-catalog'));
      await tester.ensureVisible(catalogButton);
      await tester.tap(catalogButton);
      await tester.pumpAndSettle();

      expect(gateway.calls, ['status', 'catalog']);
      expect(
        find.byKey(const Key('collaboration-deployment-workflow-section')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('collaboration-mcp-install-workflow-section')),
        findsOneWidget,
      );
      expect(find.text('Local LicoLite assembly'), findsOneWidget);
      expect(find.textContaining('result awaits deployment'), findsOneWidget);
      expect(find.text('Server Core'), findsOneWidget);
      expect(find.text('Selected MCP'), findsOneWidget);
    },
  );

  testWidgets(
    'plan review displays source ref and binds apply to shown digest',
    (tester) async {
      final gateway = _WidgetGateway(statusState: _enabledState);
      final controller = OptionalCollaborationController(gateway: gateway);
      addTearDown(controller.dispose);
      await _pumpSettings(tester, controller);

      await tester.tap(find.byKey(const Key('collaboration-load-status')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('collaboration-github-url')),
        'https://github.com/example/collaboration-plugin',
      );
      await tester.enterText(
        find.byKey(const Key('collaboration-git-ref')),
        optionalCollaborationTestCommit,
      );
      final planConfirmation = find.byKey(
        const Key('collaboration-confirm-install-plan-download'),
      );
      await tester.ensureVisible(planConfirmation);
      await tester.tap(planConfirmation);
      await tester.pump();
      final planButton = find.byKey(const Key('collaboration-plan-install'));
      await tester.ensureVisible(planButton);
      await tester.tap(planButton);
      await tester.pumpAndSettle();

      expect(gateway.calls, ['status', 'plan']);
      expect(
        find.text('https://github.com/example/collaboration-plugin.git'),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('collaboration-plan-source-ref')),
        findsOneWidget,
      );
      expect(find.text(optionalCollaborationTestCommit), findsWidgets);
      expect(find.text(_digest), findsOneWidget);

      final applyFinder = find.byKey(const Key('collaboration-apply-install'));
      expect(tester.widget<FilledButton>(applyFinder).onPressed, isNull);
      final confirmation = find.byKey(
        const Key('collaboration-confirm-install'),
      );
      await tester.ensureVisible(confirmation);
      await tester.tap(confirmation);
      await tester.pump();
      expect(tester.widget<FilledButton>(applyFinder).onPressed, isNotNull);

      await tester.ensureVisible(applyFinder);
      await tester.tap(applyFinder);
      await tester.pumpAndSettle();
      expect(gateway.appliedDigest, _digest);
      expect(gateway.calls, ['status', 'plan', 'apply']);
      expect(gateway.calls, isNot(contains('catalog')));
    },
  );

  testWidgets(
    'runner trust import binds key source identity and exact fingerprint',
    (tester) async {
      final gateway = _WidgetGateway(statusState: _enabledWithoutTrustState);
      final controller = OptionalCollaborationController(gateway: gateway);
      addTearDown(controller.dispose);
      await _pumpSettings(tester, controller);

      await tester.tap(find.byKey(const Key('collaboration-load-status')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('collaboration-runner-trust-key-id')),
        optionalCollaborationTestRunnerKeyId,
      );
      await tester.enterText(
        find.byKey(
          const Key('collaboration-runner-trust-public-key-base64url'),
        ),
        optionalCollaborationTestRunnerPublicKey,
      );
      await tester.enterText(
        find.byKey(
          const Key('collaboration-runner-trust-source-repository-url'),
        ),
        optionalCollaborationTestRunnerRepository,
      );
      await tester.enterText(
        find.byKey(const Key('collaboration-runner-trust-fingerprint-sha256')),
        optionalCollaborationTestRunnerFingerprint,
      );

      final importButton = find.byKey(
        const Key('collaboration-runner-trust-import'),
      );
      expect(tester.widget<FilledButton>(importButton).onPressed, isNull);
      final importConfirmation = find.byKey(
        const Key('collaboration-runner-trust-confirm'),
      );
      await tester.ensureVisible(importConfirmation);
      await tester.tap(importConfirmation);
      await tester.pump();
      expect(tester.widget<FilledButton>(importButton).onPressed, isNotNull);
      await tester.ensureVisible(importButton);
      await tester.tap(importButton);
      await tester.pumpAndSettle();

      expect(gateway.calls, ['status', 'trust-import:true']);
      expect(
        gateway.importedRunnerIdentity,
        optionalCollaborationOfficialRunnerIdentity,
      );
      expect(
        gateway.importedSourceRepository,
        optionalCollaborationTestRunnerRepository,
      );
      expect(
        find.text(optionalCollaborationTestRunnerFingerprint),
        findsWidgets,
      );
      expect(
        find.byKey(const Key('collaboration-runner-trust-remove-confirm')),
        findsOneWidget,
      );

      final removeConfirmation = find.byKey(
        const Key('collaboration-runner-trust-remove-confirm'),
      );
      await tester.ensureVisible(removeConfirmation);
      await tester.tap(removeConfirmation);
      await tester.pump();
      final removeButton = find.byKey(
        const Key('collaboration-runner-trust-remove'),
      );
      expect(tester.widget<OutlinedButton>(removeButton).onPressed, isNotNull);
      await tester.ensureVisible(removeButton);
      await tester.tap(removeButton);
      await tester.pumpAndSettle();

      expect(gateway.calls, [
        'status',
        'trust-import:true',
        'trust-remove:true',
      ]);
      expect(
        find.byKey(const Key('collaboration-runner-trust-remove-confirm')),
        findsNothing,
      );
    },
  );

  testWidgets('local deployment exposes exact plan apply and cancel controls', (
    tester,
  ) async {
    final gateway = _WidgetGateway(statusState: _installedState);
    final controller = OptionalCollaborationController(gateway: gateway);
    addTearDown(controller.dispose);
    await _pumpSettings(tester, controller);
    await _loadCatalog(tester);

    final choice = find.byKey(
      const Key('collaboration-local-choice-server-core'),
    );
    await tester.ensureVisible(choice);
    await tester.tap(choice);
    await tester.enterText(
      find.byKey(const Key('collaboration-local-destination')),
      '/tmp/licolite-local',
    );
    final planButton = find.byKey(const Key('collaboration-local-plan'));
    await tester.ensureVisible(planButton);
    await tester.tap(planButton);
    await tester.pumpAndSettle();

    expect(gateway.calls, ['status', 'catalog', 'local-plan']);
    expect(
      find.byKey(const Key('collaboration-local-plan-review')),
      findsOneWidget,
    );
    expect(find.text(_workflowPlanDigest), findsOneWidget);
    expect(find.text(_digest), findsWidgets);
    expect(find.textContaining('/tmp/licolite-local/server'), findsOneWidget);
    final apply = find.byKey(const Key('collaboration-local-apply'));
    final cancel = find.byKey(const Key('collaboration-local-cancel'));
    expect(tester.widget<FilledButton>(apply).onPressed, isNull);
    expect(tester.widget<OutlinedButton>(cancel).onPressed, isNull);

    final confirmation = find.byKey(const Key('collaboration-local-confirm'));
    await tester.ensureVisible(confirmation);
    await tester.tap(confirmation);
    await tester.pump();
    expect(tester.widget<FilledButton>(apply).onPressed, isNotNull);
    expect(tester.widget<OutlinedButton>(cancel).onPressed, isNotNull);

    await tester.ensureVisible(cancel);
    await tester.tap(cancel);
    await tester.pumpAndSettle();
    expect(gateway.calls, ['status', 'catalog', 'local-plan', 'cancel:true']);
    expect(
      find.byKey(const Key('collaboration-local-plan-review')),
      findsNothing,
    );
  });

  testWidgets(
    'local assembly remains stopped and lifecycle actions require approval',
    (tester) async {
      final gateway = _WidgetGateway(statusState: _installedState);
      final controller = OptionalCollaborationController(gateway: gateway);
      addTearDown(controller.dispose);
      await _pumpSettings(tester, controller);
      await _loadCatalog(tester);
      await tester.tap(
        find.byKey(const Key('collaboration-local-choice-server-core')),
      );
      await tester.enterText(
        find.byKey(const Key('collaboration-local-destination')),
        '/tmp/licolite-local',
      );
      final planButton = find.byKey(const Key('collaboration-local-plan'));
      await tester.ensureVisible(planButton);
      await tester.tap(planButton);
      await tester.pumpAndSettle();
      final planConfirmation = find.byKey(
        const Key('collaboration-local-confirm'),
      );
      await tester.ensureVisible(planConfirmation);
      await tester.tap(planConfirmation);
      await tester.pump();
      final apply = find.byKey(const Key('collaboration-local-apply'));
      await tester.ensureVisible(apply);
      await tester.tap(apply);
      await tester.pumpAndSettle();

      expect(
        find.byKey(Key('collaboration-local-server-$_deploymentId')),
        findsOneWidget,
      );
      expect(find.text('assembled-awaiting-deployment'), findsOneWidget);
      expect(
        find.text('digest-bound-licolite-server-runner-v1'),
        findsOneWidget,
      );
      final start = find.byKey(
        Key('collaboration-local-server-start-$_deploymentId'),
      );
      expect(tester.widget<FilledButton>(start).onPressed, isNull);
      final confirmation = find.byKey(
        Key('collaboration-local-server-confirm-$_deploymentId'),
      );
      await tester.ensureVisible(confirmation);
      await tester.tap(confirmation);
      await tester.pump();
      await tester.ensureVisible(start);
      await tester.tap(start);
      await tester.pumpAndSettle();

      final stop = find.byKey(
        Key('collaboration-local-server-stop-$_deploymentId'),
      );
      expect(stop, findsOneWidget);
      await tester.ensureVisible(confirmation);
      await tester.tap(confirmation);
      await tester.pump();
      await tester.ensureVisible(stop);
      await tester.tap(stop);
      await tester.pumpAndSettle();

      final uninstall = find.byKey(
        Key('collaboration-local-server-uninstall-$_deploymentId'),
      );
      await tester.ensureVisible(confirmation);
      await tester.tap(confirmation);
      await tester.pump();
      await tester.ensureVisible(uninstall);
      await tester.tap(uninstall);
      await tester.pumpAndSettle();
      expect(
        find.byKey(Key('collaboration-local-server-$_deploymentId')),
        findsNothing,
      );
      expect(
        gateway.calls,
        containsAll(['server-start', 'server-stop', 'server-uninstall']),
      );
    },
  );

  testWidgets(
    'MCP flow binds local agent paths and applies only after confirmation',
    (tester) async {
      final gateway = _WidgetGateway(statusState: _installedState);
      final controller = OptionalCollaborationController(gateway: gateway);
      addTearDown(controller.dispose);
      await _pumpSettings(tester, controller);
      await _loadCatalog(tester);
      expect(
        find.textContaining(
          'ACP injection and outbound bridging remain disabled',
        ),
        findsOneWidget,
      );

      final choice = find.byKey(
        const Key('collaboration-mcp-choice-selected-mcp'),
      );
      await tester.ensureVisible(choice);
      await tester.tap(choice);
      await tester.enterText(
        find.byKey(const Key('collaboration-mcp-agent-id-0')),
        'cursor',
      );
      await tester.enterText(
        find.byKey(const Key('collaboration-mcp-install-destination-0')),
        '/tmp/licoarc-mcp',
      );
      final planButton = find.byKey(const Key('collaboration-mcp-plan'));
      await tester.ensureVisible(planButton);
      await tester.tap(planButton);
      await tester.pumpAndSettle();

      expect(gateway.calls, ['status', 'catalog', 'mcp-plan']);
      expect(
        find.byKey(const Key('collaboration-mcp-plan-review')),
        findsOneWidget,
      );
      expect(
        find.textContaining('/tmp/licoarc-mcp/selected-mcp'),
        findsOneWidget,
      );
      expect(find.textContaining('uploaded file'), findsNothing);
      final apply = find.byKey(const Key('collaboration-mcp-apply'));
      expect(tester.widget<FilledButton>(apply).onPressed, isNull);

      final confirmation = find.byKey(const Key('collaboration-mcp-confirm'));
      await tester.ensureVisible(confirmation);
      await tester.tap(confirmation);
      await tester.pump();
      await tester.ensureVisible(apply);
      await tester.tap(apply);
      await tester.pumpAndSettle();

      expect(gateway.calls, [
        'status',
        'catalog',
        'mcp-plan',
        'mcp-apply:true',
      ]);
      expect(
        find.byKey(const Key('collaboration-mcp-plan-review')),
        findsNothing,
      );
    },
  );
}

Future<void> _loadCatalog(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('collaboration-load-status')));
  await tester.pumpAndSettle();
  final catalogButton = find.byKey(const Key('collaboration-load-catalog'));
  await tester.ensureVisible(catalogButton);
  await tester.tap(catalogButton);
  await tester.pumpAndSettle();
}

Future<void> _pumpSettings(
  WidgetTester tester,
  OptionalCollaborationController controller,
) {
  return tester.pumpWidget(
    MaterialApp(
      locale: const Locale('en'),
      supportedLocales: LicoStrings.supportedLocales,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ],
      home: Scaffold(
        body: SingleChildScrollView(
          child: SizedBox(
            width: 900,
            child: OptionalCollaborationSettings(controller: controller),
          ),
        ),
      ),
    ),
  );
}

final class _WidgetGateway implements OptionalCollaborationGateway {
  _WidgetGateway({required this.statusState});

  final OptionalCollaborationRuntimeState statusState;
  final List<String> calls = [];
  String appliedDigest = '';
  String importedSourceRepository = '';
  String importedRunnerIdentity = '';
  OptionalLocalServerState? localServer;

  @override
  Future<OptionalCollaborationRuntimeState> status() async {
    calls.add('status');
    return statusState;
  }

  @override
  Future<OptionalCollaborationMutation> enable({
    required bool confirmed,
  }) async {
    calls.add('enable');
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
    importedSourceRepository = sourceRepositoryUrl;
    importedRunnerIdentity = runnerIdentity;
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
  }) async {
    calls.add('trust-remove:$confirmed');
    return OptionalCollaborationRunnerTrustMutation(
      status: 'runner-trust-removed',
      fingerprintSha256: expectedFingerprintSha256,
      keyId: '',
      idempotent: false,
      sourceRepositoryUrl: expectedSourceRepositoryUrl,
      runnerIdentity: expectedRunnerIdentity,
    );
  }

  @override
  Future<OptionalCollaborationInstallPlan> planInstall({
    required String githubUrl,
    String gitRef = '',
    String pluginPath = '',
    required bool confirmed,
  }) async {
    calls.add(confirmed ? 'plan' : 'plan-unconfirmed');
    return _plan;
  }

  @override
  Future<OptionalCollaborationMutation> applyInstall({
    required String planId,
    required String expectedDigestSha256,
    required bool confirmed,
  }) async {
    calls.add('apply');
    appliedDigest = expectedDigestSha256;
    return const OptionalCollaborationMutation(
      status: 'installed',
      capabilityEnabled: true,
      pluginInstalled: true,
      pluginLoaded: false,
      loadPolicy: 'explicit-command-only',
      plugin: _plugin,
    );
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
  Future<OptionalCollaborationWorkflowCatalog> loadWorkflowCatalog() async {
    calls.add('catalog');
    return _catalog;
  }

  @override
  Future<OptionalCollaborationWorkflowApplyResult> applyLocalDeployment({
    required OptionalCollaborationWorkflowPlan plan,
    required bool confirmed,
  }) async {
    calls.add('local-apply:$confirmed');
    return OptionalCollaborationWorkflowApplyResult.fromJson(
      _workflowApplyJson(plan),
      expectedPlan: plan,
    );
  }

  @override
  Future<OptionalCollaborationWorkflowApplyResult> applyMcpInstall({
    required OptionalCollaborationWorkflowPlan plan,
    required bool confirmed,
  }) async {
    calls.add('mcp-apply:$confirmed');
    return OptionalCollaborationWorkflowApplyResult.fromJson(
      _workflowApplyJson(plan),
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
  Future<OptionalCollaborationWorkflowPlan> planLocalDeployment({
    required List<String> selectedFeatureIds,
    required String destination,
  }) async {
    calls.add('local-plan');
    return OptionalCollaborationWorkflowPlan.fromJson(
      _localWorkflowPlanJson(selectedFeatureIds, destination),
    );
  }

  @override
  Future<OptionalCollaborationWorkflowPlan> planMcpInstall({
    required List<String> selectedPluginIds,
    required List<OptionalCollaborationAgentDestination> agentDestinations,
  }) async {
    calls.add('mcp-plan');
    return OptionalCollaborationWorkflowPlan.fromJson(
      _mcpWorkflowPlanJson(selectedPluginIds, agentDestinations),
    );
  }

  @override
  Future<List<OptionalLocalServerState>> loadLocalServerStatus() async {
    calls.add('server-status');
    return localServer == null ? const [] : [localServer!];
  }

  @override
  Future<OptionalLocalServerState> startLocalServer({
    required String deploymentId,
    required bool confirmed,
  }) async {
    calls.add('server-start');
    localServer = OptionalLocalServerState.fromJson(
      _localServer('/tmp/licolite-local', const [
        'server-core',
      ], status: 'running'),
    );
    return localServer!;
  }

  @override
  Future<OptionalLocalServerState> stopLocalServer({
    required String deploymentId,
    required bool confirmed,
  }) async {
    calls.add('server-stop');
    localServer = OptionalLocalServerState.fromJson(
      _localServer('/tmp/licolite-local', const ['server-core']),
    );
    return localServer!;
  }

  @override
  Future<OptionalLocalServerUninstallResult> uninstallLocalServer({
    required String deploymentId,
    required String expectedAssemblyManifestDigestSha256,
    required bool confirmed,
  }) async {
    calls.add('server-uninstall');
    localServer = null;
    return const OptionalLocalServerUninstallResult(
      deploymentId: _deploymentId,
      assemblyManifestDigestSha256: _workflowRegistrationDigest,
      cleanupPending: false,
    );
  }

  @override
  Future<OptionalCollaborationMutation> disable({
    required bool confirmed,
  }) async {
    calls.add('disable');
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
    calls.add('uninstall');
    return const OptionalCollaborationMutation(
      status: 'uninstalled',
      capabilityEnabled: false,
      pluginInstalled: false,
      pluginLoaded: false,
      loadPolicy: 'explicit-command-only',
    );
  }
}

Map<String, dynamic> _localWorkflowPlanJson(
  List<String> selectedIds,
  String destination,
) => {
  ..._workflowPlanEnvelope('local-deployment'),
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
      'digestSha256': _workflowFileDigest,
      'bytes': 128,
    },
  ],
  'agentRegistrations': <dynamic>[],
  'assemblyPlan': _assemblyPlan(destination, selectedIds),
  'requiresPerFileApproval': false,
};

Map<String, dynamic> _mcpWorkflowPlanJson(
  List<String> selectedIds,
  List<OptionalCollaborationAgentDestination> destinations,
) => {
  ..._workflowPlanEnvelope('mcp-install'),
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
        'digestSha256': _workflowFileDigest,
        'bytes': 128,
      },
  ],
  'agentRegistrations': [
    for (var index = 0; index < destinations.length; index += 1)
      _workflowRegistrationPlan(destinations[index], selectedIds, index),
  ],
  'assemblyPlan': null,
  'requiresPerFileApproval': true,
};

Map<String, dynamic> _workflowPlanEnvelope(String kind) => {
  'ok': true,
  'status': 'planned',
  'workflowKind': kind,
  'planDigestSha256': _workflowPlanDigest,
  'packageDigestSha256': _digest,
  'pluginId': 'licolite-collaboration',
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

Map<String, dynamic> _workflowApplyJson(
  OptionalCollaborationWorkflowPlan plan,
) => {
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
      ? _localServer(plan.destination, plan.selectedIds)
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
  'pluginId': 'licolite-collaboration',
  'sourceUrl': 'https://github.com/example/licolite-bundle.git',
  'serverVersion': '1.0.0',
  'packageDigestSha256': _digest,
  'selectedComponentIds': selectedIds,
  'destination': destination,
  'assemblyAdapterId': 'licoarc-builtin-local-http-v1',
  'assemblyManifestDigestSha256': _workflowRegistrationDigest,
  'assemblyManifestBytes': 512,
  'bindHost': '127.0.0.1',
  'port': 43121,
  ...optionalCollaborationTestRunnerBindings(
    digest: _digest,
    planned: true,
    signedInventoryDigest: _workflowRegistrationDigest,
  ),
  'loopbackOnly': true,
  'preflightPassed': true,
  'pluginCodeWillExecute': false,
  'externalFileTransferAuthorized': false,
};

Map<String, dynamic> _localServer(
  String destination,
  List<String> selectedIds, {
  String status = 'assembled-awaiting-deployment',
}) => {
  'deploymentId': _deploymentId,
  'status': status,
  'sourceUrl': 'https://github.com/example/licolite-bundle.git',
  'serverVersion': '1.0.0',
  'packageDigestSha256': _digest,
  'selectedComponentIds': selectedIds,
  'destination': destination,
  'assemblyAdapterId': 'licoarc-builtin-local-http-v1',
  'assemblyManifestDigestSha256': _workflowRegistrationDigest,
  'bindHost': '127.0.0.1',
  'port': 43121,
  ...optionalCollaborationTestRunnerBindings(
    digest: _digest,
    planned: false,
    status: status,
    signedInventoryDigest: _workflowRegistrationDigest,
  ),
  'loopbackOnly': true,
  'pluginCodeExecuted': false,
  'externalFileTransferAuthorized': false,
};

Map<String, dynamic> _workflowRegistrationPlan(
  OptionalCollaborationAgentDestination destination,
  List<String> selectedIds,
  int index,
) {
  final registrationId =
      '00000000-0000-4000-8000-${(index + 10).toString().padLeft(12, '0')}';
  return {
    'agentId': destination.agentId,
    'registrationId': registrationId,
    'destination':
        '/tmp/licoarc-private/${destination.agentId}/$registrationId.json',
    'digestSha256': _workflowRegistrationDigest,
    'registration': {
      'schemaVersion': 'licoarc.mcp-agent-registration.v2',
      'registrationId': registrationId,
      'registrationDigestSha256': _workflowRegistrationDigest,
      'agentId': destination.agentId,
      'collaborationPluginId': 'licolite-collaboration',
      'packageDigestSha256': _digest,
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
      'bridgeKind': 'licoarc-stdio-mcp-gate',
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
  id: 'licolite-collaboration',
  displayName: 'LicoLite Collaboration',
  version: '1.0.0',
  packageDigestSha256: _digest,
  capabilities: ['local-deployment', 'mcp-install'],
  sourceUrl: 'https://github.com/example/collaboration-plugin.git',
  sourceCommitOid: optionalCollaborationTestCommit,
  signedPackageInventoryDigestSha256: _workflowRegistrationDigest,
  runnerTrustKeyId: optionalCollaborationTestRunnerKeyId,
  runnerTrustFingerprintSha256: optionalCollaborationTestRunnerFingerprint,
);

const _enabledState = OptionalCollaborationRuntimeState(
  capabilityEnabled: true,
  pluginInstalled: false,
  pluginLoaded: false,
  loadPolicy: 'explicit-command-only',
  runnerTrust: optionalCollaborationTestRunnerTrust,
);

const _enabledWithoutTrustState = OptionalCollaborationRuntimeState(
  capabilityEnabled: true,
  pluginInstalled: false,
  pluginLoaded: false,
  loadPolicy: 'explicit-command-only',
);

const _installedState = OptionalCollaborationRuntimeState(
  capabilityEnabled: true,
  pluginInstalled: true,
  pluginLoaded: false,
  loadPolicy: 'explicit-command-only',
  plugin: _plugin,
  runnerTrust: optionalCollaborationTestRunnerTrust,
);

const _plan = OptionalCollaborationInstallPlan(
  planId: '00000000-0000-4000-8000-000000000000',
  sourceUrl: 'https://github.com/example/collaboration-plugin.git',
  sourceRef: optionalCollaborationTestCommit,
  pluginPath: '',
  plugin: OptionalCollaborationPluginSummary(
    id: 'licolite-collaboration',
    displayName: 'LicoLite Collaboration',
    version: '1.0.0',
    capabilities: ['local-deployment', 'mcp-install'],
  ),
  packageDigestSha256: _digest,
  fileCount: 4,
  totalBytes: 2048,
  expiresAtEpochSeconds: 2000000000,
  requiresDirectConfirmation: true,
  runnerTrust: optionalCollaborationTestRunnerTrust,
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
