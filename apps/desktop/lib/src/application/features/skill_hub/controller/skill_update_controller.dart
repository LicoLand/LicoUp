import 'package:licoup/src/application/features/skill_hub/controller/skill_hub_status.dart';
import 'package:licoup/src/application/features/skill_hub/controller/skill_operation_controller.dart';
import 'package:licoup/src/application/features/skill_hub/services/skill_update_service.dart';

class SkillUpdateController extends SkillOperationController {
  SkillUpdateController({
    required SkillUpdateService service,
    required super.onStatus,
  }) : _service = service;

  final SkillUpdateService _service;

  Map<String, dynamic>? plan;
  Map<String, dynamic>? actionResult;

  Future<void> preview({
    required String agent,
    required String skillId,
    String githubUrl = '',
    String mirrorPath = '',
    String installRoot = '',
  }) => runOperation(
    busyChinese: '正在生成技能更新计划。',
    busyEnglish: 'Preparing the skill update plan.',
    failureChinese: '技能更新计划失败。',
    failureEnglish: 'The skill update plan failed.',
    failureCode: 'skill_update_plan_failed',
    action: () async {
      plan = await _service.plan(
        agent: agent,
        skillId: skillId,
        githubUrl: githubUrl,
        mirrorPath: mirrorPath,
        installRoot: installRoot,
      );
      actionResult = plan;
      reportStatus(
        SkillHubStatusUpdate(
          chinese: '已生成 $skillId 的更新计划，请确认后执行。',
          english:
              'Prepared the update plan for $skillId. Confirm it to apply.',
        ),
      );
    },
  );

  Future<void> apply({
    required String agent,
    required String skillId,
    required String confirmation,
    String githubUrl = '',
    String mirrorPath = '',
    String installRoot = '',
  }) => runOperation(
    busyChinese: '正在执行已确认的技能更新。',
    busyEnglish: 'Applying the confirmed skill update.',
    failureChinese: '技能更新失败。',
    failureEnglish: 'The skill update failed.',
    failureCode: 'skill_update_apply_failed',
    action: () async {
      actionResult = await _service.apply(
        agent: agent,
        skillId: skillId,
        confirmation: confirmation,
        githubUrl: githubUrl,
        mirrorPath: mirrorPath,
        installRoot: installRoot,
      );
      reportStatus(
        SkillHubStatusUpdate(
          chinese: '已更新 $skillId。',
          english: 'Updated $skillId.',
        ),
      );
    },
  );

  Future<void> configure({
    required String agent,
    required String skillId,
    required bool enabled,
    String githubUrl = '',
    String mirrorPath = '',
  }) => runOperation(
    busyChinese: '正在保存技能更新配置。',
    busyEnglish: 'Saving the skill update configuration.',
    failureChinese: '技能更新配置保存失败。',
    failureEnglish: 'Saving the skill update configuration failed.',
    failureCode: 'skill_update_configuration_failed',
    action: () async {
      actionResult = await _service.configure(
        agent: agent,
        skillId: skillId,
        enabled: enabled,
        githubUrl: githubUrl,
        mirrorPath: mirrorPath,
      );
      reportStatus(
        SkillHubStatusUpdate(
          chinese: enabled ? '已启用技能自动更新。' : '已停用技能自动更新。',
          english: enabled
              ? 'Enabled automatic skill updates.'
              : 'Disabled automatic skill updates.',
        ),
      );
    },
  );

  Future<void> runConfigured({required String agent, String skillId = ''}) =>
      runOperation(
        busyChinese: '正在执行用户触发的技能更新。',
        busyEnglish: 'Running the user-triggered skill updates.',
        failureChinese: '配置更新执行失败。',
        failureEnglish: 'Running configured skill updates failed.',
        failureCode: 'skill_configured_update_failed',
        action: () async {
          actionResult = await _service.run(agent: agent, skillId: skillId);
          reportStatus(
            const SkillHubStatusUpdate(
              chinese: '用户触发的技能更新已完成。',
              english: 'The user-triggered skill updates finished.',
            ),
          );
        },
      );
}
