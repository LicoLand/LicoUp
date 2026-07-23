import 'package:flutter_client/src/application/features/skill_hub/controller/skill_hub_controller.dart';
import 'package:flutter_client/src/application/features/skill_hub/controller/skill_delete_controller.dart';
import 'package:flutter_client/src/application/features/skill_hub/controller/skill_update_controller.dart';
import 'package:flutter_client/src/application/features/skill_hub/controller/skill_usage_controller.dart';
import 'package:flutter_client/src/application/features/skill_hub/services/skill_auto_update_scheduler.dart';
import 'package:flutter_client/src/contracts/skill_delete.dart';
import 'package:flutter_client/src/contracts/skill_hub_preferences.dart';
import 'package:flutter_client/src/contracts/skill_update.dart';
import 'package:flutter_client/src/contracts/skill_usage.dart';

mixin ClientSkillHubFacade
    implements SkillUpdateViewModel, SkillDeleteViewModel, SkillUsageViewModel {
  SkillHubController get skillHubController;
  SkillUpdateController get skillUpdateController;
  SkillDeleteController get skillDeleteController;
  SkillUsageController get skillUsageController;
  SkillAutoUpdateScheduler get skillAutoUpdateScheduler;

  List<Map<String, dynamic>> get skillHubPairings =>
      skillHubController.pairings;

  set skillHubPairings(List<Map<String, dynamic>> value) {
    skillHubController.replacePairings(value);
  }

  List<Map<String, dynamic>> get skillHubSkills => skillHubController.skills;

  set skillHubSkills(List<Map<String, dynamic>> value) {
    skillHubController.replaceSkills(value);
  }

  SkillHubPreferences get skillHubPreferences => skillHubController.preferences;

  set skillHubPreferences(SkillHubPreferences value) {
    skillHubController.replacePreferences(value);
  }

  Map<String, dynamic>? get skillHubActionResult =>
      skillHubController.actionResult;

  set skillHubActionResult(Map<String, dynamic>? value) {
    skillHubController.replaceActionResult(value);
  }

  Map<String, dynamic>? get skillInstallPlan => skillHubController.installPlan;

  set skillInstallPlan(Map<String, dynamic>? value) {
    skillHubController.replaceInstallPlan(value);
  }

  Map<String, dynamic>? get skillInstallResult =>
      skillHubController.installResult;

  set skillInstallResult(Map<String, dynamic>? value) {
    skillHubController.replaceInstallResult(value);
  }

  bool get isSkillHubBusy =>
      skillHubController.busy ||
      isSkillUpdateBusy ||
      isSkillDeleteBusy ||
      isSkillUsageBusy;

  // Installation, update, and removal share the managed-skill state and must
  // not overlap even though their controllers remain independently testable.
  bool get _isSkillMutationBusy =>
      skillHubController.busy ||
      skillUpdateController.busy ||
      skillDeleteController.busy;

  @override
  bool get isSkillUpdateBusy => _isSkillMutationBusy;

  @override
  bool get isSkillDeleteBusy => _isSkillMutationBusy;

  @override
  bool get isSkillUsageBusy => skillUsageController.busy;

  set isSkillHubBusy(bool value) {
    skillHubController.replaceBusy(value);
  }

  Future<void> refreshSkillHub(
    String agent, {
    bool forceRefresh = false,
    bool showProgress = true,
  }) => skillHubController.refresh(
    agent,
    forceRefresh: forceRefresh,
    showProgress: showProgress,
  );

  Future<void> requestSkillHubPairing(String agent, {String target = ''}) =>
      skillHubController.requestPairing(agent, target: target);

  Future<void> approveSkillHubPairing(String agent) =>
      skillHubController.approvePairing(agent);

  Future<void> revokeSkillHubPairing(String agent) =>
      skillHubController.revokePairing(agent);

  Future<void> previewSkillInstall({
    required String agent,
    required String url,
    String installRoot = '',
    String name = '',
    bool overwrite = false,
  }) => skillHubController.previewInstall(
    agent: agent,
    url: url,
    installRoot: installRoot,
    name: name,
    overwrite: overwrite,
  );

  Future<void> installSkillFromGitHub({
    required String agent,
    required String url,
    String installRoot = '',
    String name = '',
    bool overwrite = false,
    bool pin = false,
  }) => skillHubController.installFromGitHub(
    agent: agent,
    url: url,
    installRoot: installRoot,
    name: name,
    overwrite: overwrite,
    pin: pin,
  );

  Future<void> rollbackSkillInstall({
    required String agent,
    required String snapshotId,
  }) =>
      skillHubController.rollbackInstall(agent: agent, snapshotId: snapshotId);

  @override
  Map<String, dynamic>? get skillUpdatePlan => skillUpdateController.plan;

  @override
  Map<String, dynamic>? get skillDeletePlan => skillDeleteController.plan;

  @override
  Map<String, dynamic>? get skillUsageReport => skillUsageController.report;

  @override
  Future<void> previewSkillUpdate({
    required String agent,
    required String skillId,
    String githubUrl = '',
    String mirrorPath = '',
    String installRoot = '',
  }) => skillUpdateController.preview(
    agent: agent,
    skillId: skillId,
    githubUrl: githubUrl,
    mirrorPath: mirrorPath,
    installRoot: installRoot,
  );

  @override
  Future<void> applySkillUpdate({
    required String agent,
    required String skillId,
    required String confirmation,
    String githubUrl = '',
    String mirrorPath = '',
    String installRoot = '',
  }) => skillUpdateController.apply(
    agent: agent,
    skillId: skillId,
    confirmation: confirmation,
    githubUrl: githubUrl,
    mirrorPath: mirrorPath,
    installRoot: installRoot,
  );

  @override
  Future<void> configureSkillAutoUpdate({
    required String agent,
    required String skillId,
    required bool enabled,
    String githubUrl = '',
    String mirrorPath = '',
  }) => skillUpdateController.configure(
    agent: agent,
    skillId: skillId,
    enabled: enabled,
    githubUrl: githubUrl,
    mirrorPath: mirrorPath,
  );

  @override
  Future<void> runConfiguredSkillUpdates({
    required String agent,
    String skillId = '',
  }) => skillUpdateController.runConfigured(agent: agent, skillId: skillId);

  @override
  Future<void> previewSkillDelete({
    required Iterable<String> agents,
    required String skillId,
    String installRoot = '',
  }) => skillDeleteController.preview(
    agents: agents,
    skillId: skillId,
    installRoot: installRoot,
  );

  @override
  Future<void> applySkillDelete({
    required Iterable<String> agents,
    required String skillId,
    required String confirmation,
    String installRoot = '',
  }) => skillDeleteController.apply(
    agents: agents,
    skillId: skillId,
    confirmation: confirmation,
    installRoot: installRoot,
  );

  @override
  Future<void> loadSkillUsage({
    int days = 30,
    String agent = '',
    String skillId = '',
  }) => skillUsageController.load(days: days, agent: agent, skillId: skillId);

  Future<void> updateSkillVisualOverride({
    required String skillId,
    String? iconId,
    String? colorToken,
  }) => skillHubController.updateVisualOverride(
    skillId: skillId,
    iconId: iconId,
    colorToken: colorToken,
  );
}
