import 'package:licoup/src/contracts/optional_collaboration_model_parsing.dart';
import 'package:licoup/src/contracts/optional_collaboration_runner_trust_models.dart';

final class OptionalCollaborationPlugin {
  const OptionalCollaborationPlugin({
    required this.id,
    required this.displayName,
    required this.version,
    required this.packageDigestSha256,
    required this.capabilities,
    required this.sourceUrl,
    this.sourceCommitOid = '',
    this.signedPackageInventoryDigestSha256 = '',
    this.runnerTrustKeyId = '',
    this.runnerTrustFingerprintSha256 = '',
  });

  final String id;
  final String displayName;
  final String version;
  final String packageDigestSha256;
  final List<String> capabilities;
  final String sourceUrl;
  final String sourceCommitOid;
  final String signedPackageInventoryDigestSha256;
  final String runnerTrustKeyId;
  final String runnerTrustFingerprintSha256;

  factory OptionalCollaborationPlugin.fromJson(Map<String, dynamic> json) {
    final digest = optionalCollaborationRequiredText(
      json,
      'packageDigestSha256',
    );
    final sourceCommitOid = optionalCollaborationRequiredText(
      json,
      'sourceCommitOid',
    );
    final signedInventoryDigest = optionalCollaborationRequiredText(
      json,
      'signedPackageInventoryDigestSha256',
    );
    final runnerTrustKeyId = optionalCollaborationRequiredText(
      json,
      'runnerTrustKeyId',
    );
    final runnerTrustFingerprint = optionalCollaborationRequiredText(
      json,
      'runnerTrustFingerprintSha256',
    );
    if (!optionalCollaborationIsSha256(digest) ||
        !optionalCollaborationIsSha256(signedInventoryDigest) ||
        !optionalCollaborationIsCommitOid(sourceCommitOid) ||
        !RegExp(r'^[a-z0-9-]{1,128}$').hasMatch(runnerTrustKeyId) ||
        !optionalCollaborationIsSha256(runnerTrustFingerprint)) {
      throw const FormatException('optional_collaboration_digest_invalid');
    }
    return OptionalCollaborationPlugin(
      id: optionalCollaborationRequiredText(json, 'pluginId'),
      displayName: optionalCollaborationRequiredText(json, 'displayName'),
      version: optionalCollaborationRequiredText(json, 'version'),
      packageDigestSha256: digest,
      capabilities: optionalCollaborationBoundedStringList(
        json['capabilities'],
        maxItems: 32,
      ),
      sourceUrl: _sourceUrl(json['source']),
      sourceCommitOid: sourceCommitOid,
      signedPackageInventoryDigestSha256: signedInventoryDigest,
      runnerTrustKeyId: runnerTrustKeyId,
      runnerTrustFingerprintSha256: runnerTrustFingerprint,
    );
  }
}

final class OptionalCollaborationRuntimeState {
  const OptionalCollaborationRuntimeState({
    required this.capabilityEnabled,
    required this.pluginInstalled,
    required this.pluginLoaded,
    required this.loadPolicy,
    this.plugin,
    this.runnerTrust,
  });

  const OptionalCollaborationRuntimeState.disabled()
    : capabilityEnabled = false,
      pluginInstalled = false,
      pluginLoaded = false,
      loadPolicy = 'explicit-command-only',
      plugin = null,
      runnerTrust = null;

  final bool capabilityEnabled;
  final bool pluginInstalled;
  final bool pluginLoaded;
  final String loadPolicy;
  final OptionalCollaborationPlugin? plugin;
  final OptionalCollaborationRunnerTrust? runnerTrust;

  factory OptionalCollaborationRuntimeState.fromJson(
    Map<String, dynamic> json,
  ) {
    final plugin = _optionalPlugin(json['plugin']);
    final runnerTrust = _optionalRunnerTrust(json['runnerTrust']);
    final capabilityEnabled = json['capabilityEnabled'] == true;
    final pluginInstalled = json['pluginInstalled'] == true;
    final pluginLoaded = json['pluginLoaded'] == true;
    if (pluginInstalled != (plugin != null)) {
      throw const FormatException(
        'optional_collaboration_installed_plugin_invalid',
      );
    }
    if (pluginLoaded && (!capabilityEnabled || !pluginInstalled)) {
      throw const FormatException(
        'optional_collaboration_loaded_state_invalid',
      );
    }
    if (plugin != null &&
        (runnerTrust == null ||
            plugin.runnerTrustKeyId != runnerTrust.keyId ||
            plugin.runnerTrustFingerprintSha256 !=
                runnerTrust.fingerprintSha256)) {
      throw const FormatException(
        'optional_collaboration_runner_trust_binding_invalid',
      );
    }
    final loadPolicy = optionalCollaborationRequiredText(json, 'loadPolicy');
    if (loadPolicy != 'explicit-command-only') {
      throw const FormatException('optional_collaboration_load_policy_invalid');
    }
    return OptionalCollaborationRuntimeState(
      capabilityEnabled: capabilityEnabled,
      pluginInstalled: pluginInstalled,
      pluginLoaded: pluginLoaded,
      loadPolicy: loadPolicy,
      plugin: plugin,
      runnerTrust: runnerTrust,
    );
  }

  OptionalCollaborationRuntimeState mergeMutation(
    OptionalCollaborationMutation mutation,
  ) {
    final retainedPlugin = mutation.pluginInstalled
        ? mutation.plugin ?? plugin
        : null;
    return OptionalCollaborationRuntimeState(
      capabilityEnabled: mutation.capabilityEnabled,
      pluginInstalled: mutation.pluginInstalled,
      pluginLoaded: mutation.pluginLoaded,
      loadPolicy: mutation.loadPolicy,
      plugin: retainedPlugin,
      runnerTrust: runnerTrust,
    );
  }

  OptionalCollaborationRuntimeState withRunnerTrust(
    OptionalCollaborationRunnerTrust? trust,
  ) {
    return OptionalCollaborationRuntimeState(
      capabilityEnabled: capabilityEnabled,
      pluginInstalled: pluginInstalled,
      pluginLoaded: pluginLoaded,
      loadPolicy: loadPolicy,
      plugin: plugin,
      runnerTrust: trust,
    );
  }
}

final class OptionalCollaborationMutation {
  const OptionalCollaborationMutation({
    required this.status,
    required this.capabilityEnabled,
    required this.pluginInstalled,
    required this.pluginLoaded,
    required this.loadPolicy,
    this.plugin,
  });

  final String status;
  final bool capabilityEnabled;
  final bool pluginInstalled;
  final bool pluginLoaded;
  final String loadPolicy;
  final OptionalCollaborationPlugin? plugin;

  factory OptionalCollaborationMutation.fromJson(Map<String, dynamic> json) {
    final plugin = _optionalPlugin(json['plugin']);
    return OptionalCollaborationMutation(
      status: optionalCollaborationRequiredText(json, 'status'),
      capabilityEnabled: json['capabilityEnabled'] == true,
      pluginInstalled: json['pluginInstalled'] == true || plugin != null,
      pluginLoaded: json['pluginLoaded'] == true,
      loadPolicy: optionalCollaborationOptionalText(json, 'loadPolicy').isEmpty
          ? 'explicit-command-only'
          : optionalCollaborationOptionalText(json, 'loadPolicy'),
      plugin: plugin,
    );
  }
}

OptionalCollaborationPlugin? _optionalPlugin(Object? value) {
  if (value == null) return null;
  if (value is! Map) {
    throw const FormatException('optional_collaboration_plugin_invalid');
  }
  return OptionalCollaborationPlugin.fromJson(
    value.map((key, item) => MapEntry(key.toString(), item)),
  );
}

OptionalCollaborationRunnerTrust? _optionalRunnerTrust(Object? value) {
  if (value == null) return null;
  if (value is! Map) {
    throw const FormatException('optional_collaboration_runner_trust_invalid');
  }
  return OptionalCollaborationRunnerTrust.fromJson(
    value.map((key, item) => MapEntry(key.toString(), item)),
  );
}

String _sourceUrl(Object? value) {
  if (value is! Map) {
    throw const FormatException('optional_collaboration_source_invalid');
  }
  final map = value.map((key, item) => MapEntry(key.toString(), item));
  final source = optionalCollaborationRequiredText(map, 'url');
  if (!optionalCollaborationIsGitHubRepositoryUrl(source)) {
    throw const FormatException('optional_collaboration_source_invalid');
  }
  return source;
}
