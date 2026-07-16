import 'package:flutter_client/src/application/features/settings/controller/optional_collaboration_controller_context.dart';
import 'package:flutter_client/src/application/features/settings/controller/optional_collaboration_plugin_binding.dart';
import 'package:flutter_client/src/contracts/optional_collaboration_models.dart';

final class OptionalCollaborationLifecycleActions {
  const OptionalCollaborationLifecycleActions(this.context);

  final OptionalCollaborationControllerContext context;

  Future<bool> loadStatus() async {
    if (!context.beginAction()) return false;
    try {
      context.state = await context.gateway.status();
      context.statusLoaded = true;
      context.clearWorkflowCatalog();
      context.reportAction(
        '可选协作状态已加载。',
        'Optional collaboration status loaded.',
      );
      return true;
    } catch (_) {
      context.failAction(
        'optional_collaboration_status_failed',
        '可选协作状态加载失败。',
        'Failed to load optional collaboration status.',
      );
      return false;
    } finally {
      context.endAction();
    }
  }

  Future<bool> enable({required bool confirmed}) async {
    if (!confirmed) {
      return context.rejectAction(
        'optional_collaboration_enable_confirmation_required',
        '启用前需要直接确认。',
        'Direct confirmation is required before enabling.',
      );
    }
    if (!context.beginAction()) return false;
    try {
      final prior = context.state;
      final mutation = await context.gateway.enable(confirmed: true);
      if (mutation.status != 'enabled' ||
          !mutation.capabilityEnabled ||
          mutation.pluginLoaded ||
          mutation.pluginInstalled != (prior?.pluginInstalled == true) ||
          !_mutationPluginPreservesPrior(mutation, prior)) {
        throw const FormatException(
          'optional_collaboration_enable_binding_invalid',
        );
      }
      context.state =
          (context.state ?? const OptionalCollaborationRuntimeState.disabled())
              .mergeMutation(mutation);
      context.statusLoaded = true;
      context.reportAction(
        '可选协作已启用，但插件尚未加载。',
        'Optional collaboration enabled; no plugin was loaded.',
      );
      return true;
    } catch (_) {
      context.failAction(
        'optional_collaboration_enable_failed',
        '可选协作启用失败。',
        'Failed to enable optional collaboration.',
      );
      return false;
    } finally {
      context.endAction();
    }
  }

  Future<bool> disable({required bool confirmed}) async {
    if (!confirmed) {
      return context.rejectAction(
        'optional_collaboration_disable_confirmation_required',
        '停用前需要直接确认。',
        'Direct confirmation is required before disabling.',
      );
    }
    if (!context.beginAction()) return false;
    try {
      final prior = context.state;
      final mutation = await context.gateway.disable(confirmed: true);
      if (mutation.status != 'disabled' ||
          mutation.capabilityEnabled ||
          mutation.pluginLoaded ||
          mutation.pluginInstalled != (prior?.pluginInstalled == true) ||
          !_mutationPluginPreservesPrior(mutation, prior)) {
        throw const FormatException(
          'optional_collaboration_disable_binding_invalid',
        );
      }
      context.state =
          (context.state ?? const OptionalCollaborationRuntimeState.disabled())
              .mergeMutation(mutation);
      context.statusLoaded = true;
      await context.purgeWorkflowCatalog();
      context.reportAction('可选协作已停用。', 'Optional collaboration disabled.');
      return true;
    } catch (_) {
      context.failAction(
        'optional_collaboration_disable_failed',
        '可选协作停用失败。',
        'Failed to disable optional collaboration.',
      );
      return false;
    } finally {
      context.endAction();
    }
  }

  Future<bool> uninstall({required bool confirmed}) async {
    final digest = context.state?.plugin?.packageDigestSha256 ?? '';
    if (digest.isEmpty) {
      return context.rejectAction(
        'optional_collaboration_uninstall_digest_required',
        '请先加载包含已安装摘要的状态。',
        'Load the installed digest before uninstalling.',
      );
    }
    if (!confirmed) {
      return context.rejectAction(
        'optional_collaboration_uninstall_confirmation_required',
        '卸载前需要确认精确摘要。',
        'Confirm the exact digest before uninstalling.',
      );
    }
    if (!context.beginAction()) return false;
    try {
      final mutation = await context.gateway.uninstall(
        expectedDigestSha256: digest,
        confirmed: true,
      );
      if (mutation.status != 'uninstalled' ||
          mutation.pluginInstalled ||
          mutation.pluginLoaded ||
          mutation.plugin != null) {
        throw const FormatException(
          'optional_collaboration_uninstall_binding_invalid',
        );
      }
      context.state =
          (context.state ?? const OptionalCollaborationRuntimeState.disabled())
              .mergeMutation(mutation);
      context.statusLoaded = true;
      context.installPlan = null;
      await context.purgeWorkflowCatalog();
      context.reportAction(
        '可选协作插件已卸载。',
        'Optional collaboration plugin uninstalled.',
      );
      return true;
    } catch (_) {
      context.failAction(
        'optional_collaboration_uninstall_failed',
        '插件卸载失败。',
        'Failed to uninstall the plugin.',
      );
      return false;
    } finally {
      context.endAction();
    }
  }
}

bool _mutationPluginPreservesPrior(
  OptionalCollaborationMutation mutation,
  OptionalCollaborationRuntimeState? prior,
) {
  final existing = prior?.plugin;
  final projected = mutation.plugin;
  if (existing == null) return projected == null;
  return projected == null ||
      optionalCollaborationSameInstalledPlugin(projected, existing);
}
