import 'dart:convert';

import 'package:flutter_client/src/application/features/settings/controller/optional_collaboration_controller_context.dart';
import 'package:flutter_client/src/contracts/optional_collaboration_model_parsing.dart';
import 'package:flutter_client/src/contracts/optional_collaboration_models.dart';

final class OptionalCollaborationRunnerTrustActions {
  const OptionalCollaborationRunnerTrustActions(this.context);

  final OptionalCollaborationControllerContext context;

  Future<bool> importTrust({
    required String keyId,
    required String publicKeyBase64url,
    required String sourceRepositoryUrl,
    required String expectedFingerprintSha256,
    required bool confirmed,
  }) async {
    if (context.state?.pluginInstalled == true) {
      return context.rejectAction(
        'optional_collaboration_runner_trust_change_requires_uninstall',
        '更换 runner 信任前必须先卸载插件。',
        'Uninstall the plugin before changing runner trust.',
      );
    }
    if (!confirmed) {
      return context.rejectAction(
        'optional_collaboration_runner_trust_import_confirmation_required',
        '导入 runner 信任根前需要单独直接确认。',
        'Separate direct confirmation is required before importing runner trust.',
      );
    }
    final normalizedKeyId = keyId.trim();
    final normalizedPublicKey = publicKeyBase64url.trim();
    final normalizedSourceRepositoryUrl = sourceRepositoryUrl.trim();
    final normalizedFingerprint = expectedFingerprintSha256.trim();
    if (!_validKeyId(normalizedKeyId) ||
        !_validPublicKey(normalizedPublicKey) ||
        !optionalCollaborationIsGitHubRepositoryUrl(
          normalizedSourceRepositoryUrl,
        ) ||
        !optionalCollaborationIsSha256(normalizedFingerprint)) {
      return context.rejectAction(
        'optional_collaboration_runner_trust_input_invalid',
        '请核对 key ID、Ed25519 base64url 公钥和 SHA-256 指纹。',
        'Review the key ID, Ed25519 base64url public key, and SHA-256 fingerprint.',
      );
    }
    if (!context.beginAction()) return false;
    try {
      final mutation = await context.gateway.importRunnerTrust(
        keyId: normalizedKeyId,
        publicKeyBase64url: normalizedPublicKey,
        sourceRepositoryUrl: normalizedSourceRepositoryUrl,
        runnerIdentity: optionalCollaborationOfficialRunnerIdentity,
        expectedFingerprintSha256: normalizedFingerprint,
        confirmed: true,
      );
      final trust = mutation.trust;
      if (trust == null ||
          trust.keyId != normalizedKeyId ||
          trust.fingerprintSha256 != normalizedFingerprint ||
          trust.sourceRepositoryUrl != normalizedSourceRepositoryUrl ||
          trust.runnerIdentity != optionalCollaborationOfficialRunnerIdentity) {
        throw const FormatException(
          'optional_collaboration_runner_trust_binding_invalid',
        );
      }
      context.state =
          (context.state ?? const OptionalCollaborationRuntimeState.disabled())
              .withRunnerTrust(trust);
      context.statusLoaded = true;
      context.installPlan = null;
      context.clearWorkflowCatalog();
      context.reportAction(
        'Runner 信任根已按精确指纹导入。',
        'Runner trust was imported with the exact fingerprint.',
      );
      return true;
    } catch (_) {
      context.failAction(
        'optional_collaboration_runner_trust_import_failed',
        'Runner 信任根导入失败。',
        'Failed to import runner trust.',
      );
      return false;
    } finally {
      context.endAction();
    }
  }

  Future<bool> removeTrust({required bool confirmed}) async {
    final trust = context.state?.runnerTrust;
    if (trust == null) {
      return context.rejectAction(
        'optional_collaboration_runner_trust_missing',
        '未找到可移除的 runner 信任根。',
        'No runner trust is available to remove.',
      );
    }
    if (context.state?.pluginInstalled == true) {
      return context.rejectAction(
        'optional_collaboration_runner_trust_remove_requires_uninstall',
        '移除 runner 信任前必须先卸载插件。',
        'Uninstall the plugin before removing runner trust.',
      );
    }
    if (!confirmed) {
      return context.rejectAction(
        'optional_collaboration_runner_trust_remove_confirmation_required',
        '移除 runner 信任根前需要单独直接确认。',
        'Separate direct confirmation is required before removing runner trust.',
      );
    }
    if (!context.beginAction()) return false;
    try {
      final mutation = await context.gateway.removeRunnerTrust(
        expectedFingerprintSha256: trust.fingerprintSha256,
        expectedSourceRepositoryUrl: trust.sourceRepositoryUrl,
        expectedRunnerIdentity: trust.runnerIdentity,
        confirmed: true,
      );
      if (mutation.imported ||
          mutation.fingerprintSha256 != trust.fingerprintSha256 ||
          mutation.sourceRepositoryUrl != trust.sourceRepositoryUrl ||
          mutation.runnerIdentity != trust.runnerIdentity) {
        throw const FormatException(
          'optional_collaboration_runner_trust_binding_invalid',
        );
      }
      context.state = context.state!.withRunnerTrust(null);
      context.statusLoaded = true;
      context.installPlan = null;
      context.clearWorkflowCatalog();
      context.reportAction('Runner 信任根已移除。', 'Runner trust was removed.');
      return true;
    } catch (_) {
      context.failAction(
        'optional_collaboration_runner_trust_remove_failed',
        'Runner 信任根移除失败。',
        'Failed to remove runner trust.',
      );
      return false;
    } finally {
      context.endAction();
    }
  }
}

bool _validKeyId(String value) => RegExp(r'^[a-z0-9-]{1,128}$').hasMatch(value);

bool _validPublicKey(String value) {
  if (!RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(value)) return false;
  try {
    return base64Url.decode('$value=').length == 32;
  } catch (_) {
    return false;
  }
}
