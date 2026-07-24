import 'package:licoup/src/contracts/optional_collaboration_models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/optional_collaboration_test_fixtures.dart';

const _digest =
    'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd';

void main() {
  test(
    'runtime state accepts disabled installed plugin but rejects contradictions',
    () {
      final disabledInstalled = _runtimeState(
        enabled: false,
        installed: true,
        loaded: false,
        plugin: _plugin(),
      );
      expect(
        OptionalCollaborationRuntimeState.fromJson(
          disabledInstalled,
        ).pluginInstalled,
        isTrue,
      );

      expect(
        () => OptionalCollaborationRuntimeState.fromJson(
          _runtimeState(
            enabled: false,
            installed: true,
            loaded: true,
            plugin: _plugin(),
          ),
        ),
        throwsFormatException,
      );
      expect(
        () => OptionalCollaborationRuntimeState.fromJson(
          _runtimeState(enabled: true, installed: true, loaded: false),
        ),
        throwsFormatException,
      );
      expect(
        () => OptionalCollaborationRuntimeState.fromJson(
          _runtimeState(
            enabled: true,
            installed: false,
            loaded: false,
            plugin: _plugin(),
          ),
        ),
        throwsFormatException,
      );
      expect(
        () => OptionalCollaborationRuntimeState.fromJson({
          ..._runtimeState(enabled: false, installed: false, loaded: false),
          'loadPolicy': 'background',
        }),
        throwsFormatException,
      );
    },
  );

  test('workflow catalog requires exact loading and transfer policies', () {
    expect(
      OptionalCollaborationWorkflowCatalog.fromJson(
        _catalog(),
      ).localDeploymentChoices,
      hasLength(1),
    );

    for (final invalid in [
      {..._catalog(), 'pluginLoaded': false},
      {..._catalog(), 'loadPolicy': 'automatic'},
      {..._catalog(), 'externalTransferPolicy': 'implicit'},
    ]) {
      expect(
        () => OptionalCollaborationWorkflowCatalog.fromJson(invalid),
        throwsFormatException,
      );
    }
  });

  test(
    'workflow choices require unique ids and unique relative package paths',
    () {
      final duplicateId = _catalog();
      _deploymentChoices(duplicateId).add({
        'id': 'server-core',
        'label': 'Duplicate',
        'packagePath': 'payload/other',
      });
      expect(
        () => OptionalCollaborationWorkflowCatalog.fromJson(duplicateId),
        throwsFormatException,
      );

      final duplicatePath = _catalog();
      _deploymentChoices(duplicatePath).add({
        'id': 'server-extra',
        'label': 'Duplicate path',
        'packagePath': 'payload/server-core',
      });
      expect(
        () => OptionalCollaborationWorkflowCatalog.fromJson(duplicatePath),
        throwsFormatException,
      );

      final escapingPath = _catalog();
      (_deploymentChoices(escapingPath).first
              as Map<String, dynamic>)['packagePath'] =
          '../outside';
      expect(
        () => OptionalCollaborationWorkflowCatalog.fromJson(escapingPath),
        throwsFormatException,
      );
    },
  );

  test(
    'install plan requires an exact commit and full runner trust binding',
    () {
      final plan = OptionalCollaborationInstallPlan.fromJson(_installPlan());
      expect(plan.sourceRef, optionalCollaborationTestCommit);
      expect(
        plan.runnerTrust?.sameAs(optionalCollaborationTestRunnerTrust),
        isTrue,
      );

      expect(
        () => OptionalCollaborationInstallPlan.fromJson({
          ..._installPlan(),
          'source': {
            ...(_installPlan()['source']! as Map<String, dynamic>),
            'ref': 'main',
          },
        }),
        throwsFormatException,
      );
      expect(
        () => OptionalCollaborationInstallPlan.fromJson({
          ..._installPlan(),
          'runnerTrust': {
            ...optionalCollaborationTestRunnerTrustJson(),
            'runnerIdentity': 'unexpected-runner',
          },
        }),
        throwsFormatException,
      );
    },
  );
}

Map<String, dynamic> _runtimeState({
  required bool enabled,
  required bool installed,
  required bool loaded,
  Map<String, dynamic>? plugin,
}) => {
  'capabilityEnabled': enabled,
  'pluginInstalled': installed,
  'pluginLoaded': loaded,
  'loadPolicy': 'explicit-command-only',
  'plugin': ?plugin,
  if (plugin != null) 'runnerTrust': optionalCollaborationTestRunnerTrustJson(),
};

Map<String, dynamic> _plugin() => {
  'pluginId': 'licomesh-collaboration',
  'displayName': 'LicoMesh Collaboration',
  'version': '1.0.0',
  'packageDigestSha256': _digest,
  'capabilities': ['local-deployment', 'mcp-install'],
  'source': {
    'kind': 'github',
    'url': 'https://github.com/example/collaboration-plugin.git',
  },
  ...optionalCollaborationTestPluginSecurityFields(
    signedInventoryDigest: _digest,
  ),
};

Map<String, dynamic> _installPlan() => {
  'ok': true,
  'status': 'planned',
  'planId': '00000000-0000-4000-8000-000000000001',
  'source': {
    'url': 'https://github.com/example/collaboration-plugin.git',
    'ref': optionalCollaborationTestCommit,
    'pluginPath': '',
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
  'runnerTrust': optionalCollaborationTestRunnerTrustJson(),
};

Map<String, dynamic> _catalog() => {
  'pluginLoaded': true,
  'loadPolicy': 'explicit-command-only',
  'plugin': _plugin(),
  'workflows': {
    'localDeployment': {
      'schemaVersion': 'licoup.collaboration.local-deployment.v1',
      'manualOnly': true,
      'features': <dynamic>[
        {
          'id': 'server-core',
          'label': 'Server Core',
          'packagePath': 'payload/server-core',
        },
      ],
    },
    'mcpInstall': {
      'schemaVersion': 'licoup.collaboration.mcp-install.v2',
      'manualOnly': true,
      'requiresPerFileApproval': true,
      'outboundPolicy': 'direct-user-exact-scope-one-shot',
      'plugins': <dynamic>[
        {
          'id': 'selected-mcp',
          'label': 'Selected MCP',
          'packagePath': 'payload/mcp-selected',
          'endpoint': 'https://example.invalid/mcp',
        },
      ],
    },
  },
  'externalTransferPolicy': 'direct-exact-operation-approval-required',
};

List<dynamic> _deploymentChoices(Map<String, dynamic> catalog) {
  final workflows = catalog['workflows']! as Map<String, dynamic>;
  final deployment = workflows['localDeployment']! as Map<String, dynamic>;
  return deployment['features']! as List<dynamic>;
}
