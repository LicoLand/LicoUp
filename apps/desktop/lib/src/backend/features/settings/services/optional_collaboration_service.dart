import 'dart:convert';

import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/contracts/optional_collaboration_gateway.dart';
import 'package:licoup/src/contracts/optional_collaboration_models.dart';
import 'package:licoup/src/contracts/optional_collaboration_local_server_models.dart';
import 'package:licoup/src/contracts/optional_collaboration_model_parsing.dart';
import 'package:licoup/src/contracts/optional_collaboration_workflow_models.dart';

/// Fixed-command adapter for the native optional-collaboration lifecycle.
///
/// No plugin-supplied value can select a native command. Workflow descriptors
/// are returned only through the typed, declarative catalog projection.
final class OptionalCollaborationService
    implements OptionalCollaborationGateway {
  const OptionalCollaborationService({required AgentCommandRunner runner})
    : _runner = runner;

  final AgentCommandRunner _runner;

  @override
  Future<OptionalCollaborationRuntimeState> status() async {
    final output = await _runner.runCli(const ['collaboration', 'status']);
    return OptionalCollaborationRuntimeState.fromJson(output);
  }

  @override
  Future<OptionalCollaborationMutation> enable({
    required bool confirmed,
  }) async {
    final output = await _runner.runCli([
      'collaboration',
      'enable',
      '--request-origin',
      'direct-user',
      '--confirmed',
      confirmed.toString(),
    ]);
    return OptionalCollaborationMutation.fromJson(output);
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
    final output = await _runner.runCli([
      'collaboration',
      'runner-trust',
      'import',
      '--request-origin',
      'direct-user',
      '--runner-trust-key-id',
      keyId,
      '--runner-trust-public-key-base64url',
      publicKeyBase64url,
      '--runner-source-repository-url',
      sourceRepositoryUrl,
      '--runner-identity',
      runnerIdentity,
      '--expected-runner-trust-fingerprint-sha256',
      expectedFingerprintSha256,
      '--confirmed',
      confirmed.toString(),
    ]);
    return OptionalCollaborationRunnerTrustMutation.fromJson(output);
  }

  @override
  Future<OptionalCollaborationRunnerTrustMutation> removeRunnerTrust({
    required String expectedFingerprintSha256,
    required String expectedSourceRepositoryUrl,
    required String expectedRunnerIdentity,
    required bool confirmed,
  }) async {
    final output = await _runner.runCli([
      'collaboration',
      'runner-trust',
      'remove',
      '--request-origin',
      'direct-user',
      '--expected-runner-trust-fingerprint-sha256',
      expectedFingerprintSha256,
      '--expected-runner-source-repository-url',
      expectedSourceRepositoryUrl,
      '--expected-runner-identity',
      expectedRunnerIdentity,
      '--confirmed',
      confirmed.toString(),
    ]);
    return OptionalCollaborationRunnerTrustMutation.fromJson(output);
  }

  @override
  Future<OptionalCollaborationInstallPlan> planInstall({
    required String githubUrl,
    String gitRef = '',
    String pluginPath = '',
    required bool confirmed,
  }) async {
    final commitOid = gitRef.trim();
    if (!optionalCollaborationIsCommitOid(commitOid)) {
      throw const FormatException('optional_collaboration_git_commit_invalid');
    }
    final args = <String>[
      'collaboration',
      'install',
      'plan',
      '--request-origin',
      'direct-user',
      '--github-url',
      githubUrl.trim(),
      '--ref',
      commitOid,
      '--confirmed',
      confirmed.toString(),
    ];
    _appendOptional(args, '--plugin-path', pluginPath);
    final output = await _runner.runCli(args);
    return OptionalCollaborationInstallPlan.fromJson(output);
  }

  @override
  Future<OptionalCollaborationMutation> applyInstall({
    required String planId,
    required String expectedDigestSha256,
    required bool confirmed,
  }) async {
    final output = await _runner.runCli([
      'collaboration',
      'install',
      'apply',
      '--request-origin',
      'direct-user',
      '--plan-id',
      planId,
      '--expected-digest-sha256',
      expectedDigestSha256,
      '--confirmed',
      confirmed.toString(),
    ]);
    return OptionalCollaborationMutation.fromJson(output);
  }

  @override
  Future<OptionalCollaborationInstallCancellation> cancelInstall({
    required OptionalCollaborationInstallPlan plan,
    required bool confirmed,
  }) async {
    final output = await _runner.runCli([
      'collaboration',
      'install',
      'cancel',
      '--request-origin',
      'direct-user',
      '--plan-id',
      plan.planId,
      '--expected-digest-sha256',
      plan.packageDigestSha256,
      '--confirmed',
      confirmed.toString(),
    ]);
    return OptionalCollaborationInstallCancellation.fromJson(
      output,
      expectedPlan: plan,
    );
  }

  @override
  Future<OptionalCollaborationWorkflowCatalog> loadWorkflowCatalog() async {
    final output = await _runner.runCli(const [
      'collaboration',
      'workflow',
      'catalog',
    ]);
    return OptionalCollaborationWorkflowCatalog.fromJson(output);
  }

  @override
  Future<OptionalCollaborationWorkflowPlan> planLocalDeployment({
    required List<String> selectedFeatureIds,
    required String destination,
  }) async {
    final output = await _runner.runCli([
      'collaboration',
      'workflow',
      'local-deployment',
      'plan',
      '--request-origin',
      'direct-user',
      '--selected-feature-ids',
      jsonEncode(selectedFeatureIds),
      '--destination',
      destination,
      '--destination-confirmed',
      'true',
    ]);
    return OptionalCollaborationWorkflowPlan.fromJson(output);
  }

  @override
  Future<OptionalCollaborationWorkflowApplyResult> applyLocalDeployment({
    required OptionalCollaborationWorkflowPlan plan,
    required bool confirmed,
  }) async {
    _requireKind(plan, OptionalCollaborationWorkflowKind.localDeployment);
    final output = await _runner.runCli([
      'collaboration',
      'workflow',
      'local-deployment',
      'apply',
      '--request-origin',
      'direct-user',
      '--selected-feature-ids',
      jsonEncode(plan.selectedIds),
      '--destination',
      plan.destination,
      '--destination-confirmed',
      'true',
      ..._planBindingArgs(plan, confirmed: confirmed),
    ]);
    return OptionalCollaborationWorkflowApplyResult.fromJson(
      output,
      expectedPlan: plan,
    );
  }

  @override
  Future<OptionalCollaborationWorkflowPlan> planMcpInstall({
    required List<String> selectedPluginIds,
    required List<OptionalCollaborationAgentDestination> agentDestinations,
  }) async {
    final output = await _runner.runCli([
      'collaboration',
      'workflow',
      'mcp-install',
      'plan',
      '--request-origin',
      'direct-user',
      '--selected-plugin-ids',
      jsonEncode(selectedPluginIds),
      '--agent-destinations',
      jsonEncode(
        agentDestinations
            .map((destination) => destination.toConfirmedJson())
            .toList(growable: false),
      ),
    ]);
    return OptionalCollaborationWorkflowPlan.fromJson(output);
  }

  @override
  Future<OptionalCollaborationWorkflowApplyResult> applyMcpInstall({
    required OptionalCollaborationWorkflowPlan plan,
    required bool confirmed,
  }) async {
    _requireKind(plan, OptionalCollaborationWorkflowKind.mcpInstall);
    final output = await _runner.runCli([
      'collaboration',
      'workflow',
      'mcp-install',
      'apply',
      '--request-origin',
      'direct-user',
      '--selected-plugin-ids',
      jsonEncode(plan.selectedIds),
      '--agent-destinations',
      jsonEncode(
        plan.agents
            .map((destination) => destination.toConfirmedJson())
            .toList(growable: false),
      ),
      ..._planBindingArgs(plan, confirmed: confirmed),
    ]);
    return OptionalCollaborationWorkflowApplyResult.fromJson(
      output,
      expectedPlan: plan,
    );
  }

  @override
  Future<OptionalCollaborationWorkflowCancellation> cancelWorkflow({
    required OptionalCollaborationWorkflowPlan plan,
    required bool confirmed,
  }) async {
    final output = await _runner.runCli([
      'collaboration',
      'workflow',
      'cancel',
      '--request-origin',
      'direct-user',
      ..._planBindingArgs(plan, confirmed: confirmed),
    ]);
    return OptionalCollaborationWorkflowCancellation.fromJson(
      output,
      expectedPlan: plan,
    );
  }

  @override
  Future<List<OptionalLocalServerState>> loadLocalServerStatus() async {
    final output = await _runner.runCli(const [
      'collaboration',
      'local-server',
      'status',
    ]);
    return parseOptionalLocalServerStatus(output);
  }

  @override
  Future<OptionalLocalServerState> startLocalServer({
    required String deploymentId,
    required bool confirmed,
  }) async {
    final output = await _runner.runCli([
      'collaboration',
      'local-server',
      'start',
      '--request-origin',
      'direct-user',
      '--deployment-id',
      deploymentId,
      '--confirmed',
      confirmed.toString(),
    ]);
    return parseOptionalLocalServerMutation(
      output,
      expectedStatus: 'deployment-started',
    );
  }

  @override
  Future<OptionalLocalServerState> stopLocalServer({
    required String deploymentId,
    required bool confirmed,
  }) async {
    final output = await _runner.runCli([
      'collaboration',
      'local-server',
      'stop',
      '--request-origin',
      'direct-user',
      '--deployment-id',
      deploymentId,
      '--confirmed',
      confirmed.toString(),
    ]);
    return parseOptionalLocalServerMutation(
      output,
      expectedStatus: 'deployment-stopped',
    );
  }

  @override
  Future<OptionalLocalServerUninstallResult> uninstallLocalServer({
    required String deploymentId,
    required String expectedAssemblyManifestDigestSha256,
    required bool confirmed,
  }) async {
    final output = await _runner.runCli([
      'collaboration',
      'local-server',
      'uninstall',
      '--request-origin',
      'direct-user',
      '--deployment-id',
      deploymentId,
      '--expected-assembly-manifest-digest-sha256',
      expectedAssemblyManifestDigestSha256,
      '--confirmed',
      confirmed.toString(),
    ]);
    return OptionalLocalServerUninstallResult.fromJson(output);
  }

  @override
  Future<OptionalCollaborationMutation> disable({
    required bool confirmed,
  }) async {
    final output = await _runner.runCli([
      'collaboration',
      'disable',
      '--request-origin',
      'direct-user',
      '--confirmed',
      confirmed.toString(),
    ]);
    return OptionalCollaborationMutation.fromJson(output);
  }

  @override
  Future<OptionalCollaborationMutation> uninstall({
    required String expectedDigestSha256,
    required bool confirmed,
  }) async {
    final output = await _runner.runCli([
      'collaboration',
      'uninstall',
      '--request-origin',
      'direct-user',
      '--expected-digest-sha256',
      expectedDigestSha256,
      '--confirmed',
      confirmed.toString(),
    ]);
    return OptionalCollaborationMutation.fromJson(output);
  }
}

List<String> _planBindingArgs(
  OptionalCollaborationWorkflowPlan plan, {
  required bool confirmed,
}) => [
  '--plan-id',
  plan.planId,
  '--expected-plan-digest-sha256',
  plan.planDigestSha256,
  '--expected-package-digest-sha256',
  plan.packageDigestSha256,
  '--confirmed',
  confirmed.toString(),
];

void _requireKind(
  OptionalCollaborationWorkflowPlan plan,
  OptionalCollaborationWorkflowKind expected,
) {
  if (plan.kind != expected) {
    throw StateError('optional_collaboration_workflow_kind_mismatch');
  }
}

void _appendOptional(List<String> args, String flag, String value) {
  final normalized = value.trim();
  if (normalized.isNotEmpty) {
    args.addAll([flag, normalized]);
  }
}
