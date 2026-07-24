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

void main() {
  test('local plan binds exact selection destination digests and files', () {
    final plan = OptionalCollaborationWorkflowPlan.fromJson(_localPlanJson());

    expect(plan.kind, OptionalCollaborationWorkflowKind.localDeployment);
    expect(plan.selectedIds, ['server-core']);
    expect(plan.destination, 'test-data/licomesh-local');
    expect(plan.fileChanges.single.destination, 'test-data/licomesh-local/server');
    expect(
      plan.matchesLocalRequest(['server-core'], 'test-data/licomesh-local'),
      isTrue,
    );
    expect(
      plan.matchesLocalRequest(['server-extra'], 'test-data/licomesh-local'),
      isFalse,
    );
  });

  test('MCP plan requires local destinations and typed registrations', () {
    final plan = OptionalCollaborationWorkflowPlan.fromJson(_mcpPlanJson());

    expect(plan.kind, OptionalCollaborationWorkflowKind.mcpInstall);
    expect(plan.agents.single.agentId, 'cursor');
    expect(plan.agentRegistrations.single.registration.selectedPluginIds, [
      'selected-mcp',
    ]);
    expect(
      plan.agentRegistrations.single.registration.payloadRoots.single.path,
      'test-data/licoup-mcp/selected-mcp',
    );
  });

  test('plans reject external transfer authorization and projection drift', () {
    final transferAuthorized = _mcpPlanJson();
    transferAuthorized['externalFileTransferAuthorized'] = true;
    expect(
      () => OptionalCollaborationWorkflowPlan.fromJson(transferAuthorized),
      throwsFormatException,
    );

    final plan = OptionalCollaborationWorkflowPlan.fromJson(_localPlanJson());
    final apply = _localApplyJson();
    apply['destination'] = 'test-data/different';
    expect(
      () => OptionalCollaborationWorkflowApplyResult.fromJson(
        apply,
        expectedPlan: plan,
      ),
      throwsFormatException,
    );

    final runnerDrift = _localApplyJson();
    final localServer = runnerDrift['localServer']! as Map<String, dynamic>;
    localServer['runnerDigestSha256'] = _fileDigest;
    expect(
      () => OptionalCollaborationWorkflowApplyResult.fromJson(
        runnerDrift,
        expectedPlan: plan,
      ),
      throwsFormatException,
    );
  });

  test('apply and cancellation must consume the exact bound plan', () {
    final plan = OptionalCollaborationWorkflowPlan.fromJson(_localPlanJson());
    final applied = OptionalCollaborationWorkflowApplyResult.fromJson(
      _localApplyJson(),
      expectedPlan: plan,
    );
    final cancelled = OptionalCollaborationWorkflowCancellation.fromJson(
      _cancelJson(),
      expectedPlan: plan,
    );

    expect(applied.plan, same(plan));
    expect(applied.cleanupPending, isFalse);
    expect(cancelled.plan, same(plan));
  });
}

Map<String, dynamic> _localPlanJson() => {
  'ok': true,
  'status': 'planned',
  'workflowKind': 'local-deployment',
  'planId': '00000000-0000-4000-8000-000000000001',
  'planDigestSha256': _planDigest,
  'packageDigestSha256': _packageDigest,
  'pluginId': 'licomesh-collaboration',
  'selectedFeatureIds': ['server-core'],
  'selectedPluginIds': null,
  'destination': 'test-data/licomesh-local',
  'agents': <dynamic>[],
  'fileChanges': [
    {
      'selectionId': 'server-core',
      'sourceRelativePath': 'payload/server-core/server',
      'destination': 'test-data/licomesh-local/server',
      'destinationRelativePath': 'server',
      'digestSha256': _fileDigest,
      'bytes': 128,
    },
  ],
  'agentRegistrations': <dynamic>[],
  'assemblyPlan': _assemblyPlan('test-data/licomesh-local', ['server-core']),
  'expiresAtEpochSeconds': 2000000000,
  'oneTime': true,
  'cancellable': true,
  'requiresDirectConfirmation': true,
  'pluginExecuted': false,
  'pluginCodeWillExecute': false,
  'assemblyAdapterWillExecute': true,
  'vendorConfigurationModified': false,
  'agentRegistrationModified': false,
  'externalFileTransferAuthorized': false,
  'outboundPolicy': null,
  'requiresPerFileApproval': false,
};

Map<String, dynamic> _mcpPlanJson() => {
  'ok': true,
  'status': 'planned',
  'workflowKind': 'mcp-install',
  'planId': '00000000-0000-4000-8000-000000000002',
  'planDigestSha256': _planDigest,
  'packageDigestSha256': _packageDigest,
  'pluginId': 'licomesh-collaboration',
  'selectedFeatureIds': null,
  'selectedPluginIds': ['selected-mcp'],
  'destination': null,
  'agents': [
    {'agentId': 'cursor', 'installDestination': 'test-data/licoup-mcp'},
  ],
  'fileChanges': [
    {
      'agentId': 'cursor',
      'selectionId': 'selected-mcp',
      'sourceRelativePath': 'payload/mcp-selected/server',
      'destination': 'test-data/licoup-mcp/selected-mcp/server',
      'destinationRelativePath': 'selected-mcp/server',
      'digestSha256': _fileDigest,
      'bytes': 128,
    },
  ],
  'agentRegistrations': [
    {
      'agentId': 'cursor',
      'registrationId': '00000000-0000-4000-8000-000000000010',
      'destination': 'test-data/licoup-private-registration.json',
      'digestSha256': _registrationDigest,
      'registration': {
        'schemaVersion': 'licoup.mcp-agent-registration.v2',
        'registrationId': '00000000-0000-4000-8000-000000000010',
        'registrationDigestSha256': _registrationDigest,
        'agentId': 'cursor',
        'collaborationPluginId': 'licomesh-collaboration',
        'packageDigestSha256': _packageDigest,
        'selectedPluginIds': ['selected-mcp'],
        'payloadRoots': [
          {'pluginId': 'selected-mcp', 'path': 'test-data/licoup-mcp/selected-mcp'},
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
    },
  ],
  'assemblyPlan': null,
  'expiresAtEpochSeconds': 2000000000,
  'oneTime': true,
  'cancellable': true,
  'requiresDirectConfirmation': true,
  'pluginExecuted': false,
  'pluginCodeWillExecute': false,
  'assemblyAdapterWillExecute': false,
  'vendorConfigurationModified': false,
  'agentRegistrationModified': false,
  'externalFileTransferAuthorized': false,
  'outboundPolicy': 'direct-user-exact-scope-one-shot',
  'requiresPerFileApproval': true,
};

Map<String, dynamic> _localApplyJson() => {
  'ok': true,
  'status': 'assembled',
  'workflowKind': 'local-deployment',
  'planId': '00000000-0000-4000-8000-000000000001',
  'planConsumed': true,
  'packageDigestSha256': _packageDigest,
  'pluginId': 'licomesh-collaboration',
  'selectedFeatureIds': ['server-core'],
  'selectedPluginIds': null,
  'destination': 'test-data/licomesh-local',
  'agents': <dynamic>[],
  'fileChanges': _localPlanJson()['fileChanges'],
  'agentRegistrations': <dynamic>[],
  'localServer': _localServer('test-data/licomesh-local', ['server-core']),
  'pluginExecuted': false,
  'pluginCodeExecuted': false,
  'assemblyAdapterExecuted': true,
  'vendorConfigurationModified': false,
  'agentRegistrationModified': false,
  'externalFileTransferAuthorized': false,
  'outboundPolicy': null,
  'requiresPerFileApproval': false,
  'cleanupPending': false,
};

Map<String, dynamic> _assemblyPlan(
  String destination,
  List<String> selectedIds,
) => {
  'deploymentId': '00000000-0000-4000-8000-000000000020',
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
    digest: _packageDigest,
    planned: true,
  ),
  'loopbackOnly': true,
  'preflightPassed': true,
  'pluginCodeWillExecute': false,
  'externalFileTransferAuthorized': false,
};

Map<String, dynamic> _localServer(
  String destination,
  List<String> selectedIds,
) => {
  'deploymentId': '00000000-0000-4000-8000-000000000020',
  'status': 'assembled-awaiting-deployment',
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
    digest: _packageDigest,
    planned: false,
  ),
  'loopbackOnly': true,
  'pluginCodeExecuted': false,
  'externalFileTransferAuthorized': false,
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
