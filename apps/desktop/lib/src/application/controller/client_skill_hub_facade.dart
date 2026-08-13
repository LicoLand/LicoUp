import 'package:licoup/src/application/features/skill_hub/controller/skill_hub_controller.dart';
import 'package:licoup/src/application/features/skill_hub/controller/skill_delete_controller.dart';
import 'package:licoup/src/application/features/skill_hub/controller/skill_usage_controller.dart';
import 'package:licoup/src/contracts/skill_delete.dart';
import 'package:licoup/src/contracts/skill_hub_preferences.dart';
import 'package:licoup/src/contracts/skill_usage.dart';

mixin ClientSkillHubFacade
    implements SkillDeleteViewModel, SkillUsageViewModel {
  SkillHubController get skillHubController;
  SkillDeleteController get skillDeleteController;
  SkillUsageController get skillUsageController;

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

  bool get isSkillHubBusy =>
      skillHubController.busy || isSkillDeleteBusy || isSkillUsageBusy;

  @override
  bool get isSkillDeleteBusy =>
      skillHubController.busy || skillDeleteController.busy;

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

  void removeSkillHubEntryAtPath(String path) =>
      skillHubController.removeSkillAtPath(path);

  Future<void> requestSkillHubPairing(String agent, {String target = ''}) =>
      skillHubController.requestPairing(agent, target: target);

  Future<void> approveSkillHubPairing(String agent) =>
      skillHubController.approvePairing(agent);

  Future<void> revokeSkillHubPairing(String agent) =>
      skillHubController.revokePairing(agent);

  @override
  Map<String, dynamic>? get skillDeletePlan => skillDeleteController.plan;

  @override
  Map<String, dynamic>? get skillDeleteResult =>
      skillDeleteController.actionResult;

  @override
  Map<String, dynamic>? get skillUsageReport => skillUsageController.report;

  @override
  Future<void> previewSkillDelete({
    required String skillId,
    required String path,
  }) => skillDeleteController.preview(skillId: skillId, path: path);

  @override
  Future<void> applySkillDelete({
    required String skillId,
    required String path,
    required String confirmation,
  }) => skillDeleteController.apply(
    skillId: skillId,
    path: path,
    confirmation: confirmation,
  );

  @override
  Future<void> loadSkillUsage({
    int days = 30,
    String agent = '',
    String skillId = '',
  }) => skillUsageController.load(days: days, agent: agent, skillId: skillId);

  @override
  Future<void> loadSkillUsageCounts() => skillUsageController.loadCounts();

  Future<void> scanSkillUsage({String agent = '', bool forceRefresh = false}) =>
      skillUsageController.scan(agent: agent, forceRefresh: forceRefresh);

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
