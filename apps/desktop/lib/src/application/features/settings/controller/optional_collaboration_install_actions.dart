import 'package:flutter_client/src/application/features/settings/controller/optional_collaboration_controller_context.dart';
import 'package:flutter_client/src/application/features/settings/controller/optional_collaboration_plugin_binding.dart';
import 'package:flutter_client/src/contracts/optional_collaboration_model_parsing.dart';
import 'package:flutter_client/src/contracts/optional_collaboration_models.dart';

final class OptionalCollaborationInstallActions {
  const OptionalCollaborationInstallActions(this.context);

  final OptionalCollaborationControllerContext context;

  Future<bool> plan({
    required String githubUrl,
    required String gitRef,
    required String pluginPath,
    required bool confirmed,
  }) async {
    if (context.state?.capabilityEnabled != true) {
      return context.rejectAction(
        'optional_collaboration_capability_disabled',
        '请先显式启用可选协作。',
        'Explicitly enable optional collaboration first.',
      );
    }
    final trust = context.state?.runnerTrust;
    if (trust == null) {
      return context.rejectAction(
        'optional_collaboration_runner_trust_missing',
        '请先导入并核对 runner 信任根。',
        'Import and verify runner trust before creating an install plan.',
      );
    }
    if (!confirmed) {
      return context.rejectAction(
        'optional_collaboration_install_plan_confirmation_required',
        '访问 GitHub 并生成安装计划前需要单独直接确认。',
        'Separate direct confirmation is required before accessing GitHub and creating an install plan.',
      );
    }
    final sourceUrl = githubUrl.trim();
    final commitOid = gitRef.trim();
    final sourcePluginPath = pluginPath.trim();
    if (!optionalCollaborationIsGitHubRepositoryUrl(sourceUrl)) {
      return context.rejectAction(
        'optional_collaboration_github_url_invalid',
        '请输入完整的 GitHub HTTPS 仓库地址。',
        'Enter a complete GitHub HTTPS repository URL.',
      );
    }
    if (!optionalCollaborationIsCommitOid(commitOid)) {
      return context.rejectAction(
        'optional_collaboration_git_commit_invalid',
        '必须填写精确的 40 位小写十六进制 Git commit SHA。',
        'Enter an exact 40-character lower-case hexadecimal Git commit SHA.',
      );
    }
    if (!context.beginAction()) return false;
    try {
      final plan = await context.gateway.planInstall(
        githubUrl: sourceUrl,
        gitRef: commitOid,
        pluginPath: sourcePluginPath,
        confirmed: true,
      );
      if (!optionalCollaborationSameGitHubRepository(
            plan.sourceUrl,
            sourceUrl,
          ) ||
          plan.sourceRef != commitOid ||
          plan.pluginPath != sourcePluginPath ||
          plan.runnerTrust == null ||
          !plan.runnerTrust!.sameAs(trust)) {
        throw const FormatException(
          'optional_collaboration_install_plan_binding_invalid',
        );
      }
      context.installPlan = plan;
      context.clearWorkflowCatalog();
      context.reportAction(
        '安装计划已生成，请核对 commit、runner 信任与 SHA-256 摘要。',
        'Install plan created. Review its commit, runner trust, and SHA-256 digest.',
      );
      return true;
    } catch (_) {
      context.installPlan = null;
      context.failAction(
        'optional_collaboration_install_plan_failed',
        '安装计划生成失败。',
        'Failed to create the install plan.',
      );
      return false;
    } finally {
      context.endAction();
    }
  }

  Future<bool> apply({required bool confirmed}) async {
    final plan = context.installPlan;
    if (plan == null) {
      return context.rejectAction(
        'optional_collaboration_install_plan_required',
        '请先生成安装计划。',
        'Create an install plan first.',
      );
    }
    if (!confirmed) return _confirmationRequired();
    final trust = context.state?.runnerTrust;
    if (trust == null ||
        plan.runnerTrust == null ||
        !plan.runnerTrust!.sameAs(trust)) {
      return context.rejectAction(
        'optional_collaboration_runner_trust_changed',
        'Runner 信任已变更，请重新生成安装计划。',
        'Runner trust changed; create a new install plan.',
      );
    }
    if (!context.beginAction()) return false;
    try {
      final mutation = await context.gateway.applyInstall(
        planId: plan.planId,
        expectedDigestSha256: plan.packageDigestSha256,
        confirmed: true,
      );
      final installed = mutation.plugin;
      if (mutation.status != 'installed' ||
          !mutation.capabilityEnabled ||
          !mutation.pluginInstalled ||
          mutation.pluginLoaded ||
          installed == null ||
          !optionalCollaborationPluginMatchesInstallPlan(
            installed,
            plan,
            trust,
          )) {
        throw const FormatException(
          'optional_collaboration_installed_plugin_binding_invalid',
        );
      }
      context.state =
          (context.state ?? const OptionalCollaborationRuntimeState.disabled())
              .mergeMutation(mutation);
      context.statusLoaded = true;
      context.installPlan = null;
      context.clearWorkflowCatalog();
      context.reportAction(
        '摘要与 runner 信任绑定的插件已安装，工作流目录仍未加载。',
        'Digest- and runner-trust-bound plugin installed; its workflow catalog remains unloaded.',
      );
      return true;
    } catch (_) {
      context.failAction(
        'optional_collaboration_install_apply_failed',
        '插件安装失败。',
        'Failed to install the plugin.',
      );
      return false;
    } finally {
      context.endAction();
    }
  }

  Future<bool> cancel({required bool confirmed}) async {
    final plan = context.installPlan;
    if (plan == null) {
      return context.rejectAction(
        'optional_collaboration_install_plan_required',
        '没有可取消的安装计划。',
        'There is no install plan to cancel.',
      );
    }
    if (!confirmed) return _confirmationRequired();
    if (!context.beginAction()) return false;
    try {
      await context.gateway.cancelInstall(plan: plan, confirmed: true);
      context.installPlan = null;
      context.reportAction(
        '安装计划已取消并作废。',
        'The install plan was cancelled and consumed.',
      );
      return true;
    } catch (_) {
      context.failAction(
        'optional_collaboration_install_cancel_failed',
        '安装计划取消失败。',
        'Failed to cancel the install plan.',
      );
      return false;
    } finally {
      context.endAction();
    }
  }

  Future<bool> loadCatalog() async {
    if (context.state?.capabilityEnabled != true ||
        context.state?.pluginInstalled != true) {
      return context.rejectAction(
        'optional_collaboration_plugin_required',
        '请先安装插件。',
        'Install the plugin first.',
      );
    }
    if (!context.beginAction()) return false;
    try {
      final installed = context.state!.plugin;
      final runnerTrust = context.state!.runnerTrust;
      final catalog = await context.gateway.loadWorkflowCatalog();
      if (installed == null ||
          runnerTrust == null ||
          !optionalCollaborationSameInstalledPlugin(
            catalog.plugin,
            installed,
          ) ||
          catalog.plugin.runnerTrustKeyId != runnerTrust.keyId ||
          catalog.plugin.runnerTrustFingerprintSha256 !=
              runnerTrust.fingerprintSha256) {
        throw const FormatException(
          'optional_collaboration_workflow_catalog_binding_invalid',
        );
      }
      context.workflowCatalog = catalog;
      context.workflows.replaceCatalog(catalog);
      context.state = OptionalCollaborationRuntimeState(
        capabilityEnabled: context.state!.capabilityEnabled,
        pluginInstalled: true,
        pluginLoaded: true,
        loadPolicy: context.state!.loadPolicy,
        plugin: catalog.plugin,
        runnerTrust: runnerTrust,
      );
      context.reportAction(
        '声明式工作流目录已按需加载。',
        'Declarative workflow catalog loaded on demand.',
      );
      return true;
    } catch (_) {
      context.clearWorkflowCatalog();
      context.failAction(
        'optional_collaboration_workflow_catalog_failed',
        '工作流目录加载失败。',
        'Failed to load the workflow catalog.',
      );
      return false;
    } finally {
      context.endAction();
    }
  }

  bool _confirmationRequired() {
    return context.rejectAction(
      'optional_collaboration_install_confirmation_required',
      '请直接确认当前 commit、runner 信任和精确摘要。',
      'Directly confirm the current commit, runner trust, and exact digest.',
    );
  }
}
