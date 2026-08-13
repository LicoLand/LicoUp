import 'package:licoup/src/application/features/skill_hub/controller/skill_hub_status.dart';
import 'package:licoup/src/application/features/skill_hub/controller/skill_operation_controller.dart';
import 'package:licoup/src/application/features/skill_hub/services/skill_delete_service.dart';

class SkillDeleteController extends SkillOperationController {
  SkillDeleteController({
    required SkillDeleteService service,
    required super.onStatus,
  }) : _service = service;

  final SkillDeleteService _service;

  Map<String, dynamic>? plan;
  Map<String, dynamic>? actionResult;

  Future<void> preview({required String skillId, required String path}) =>
      runOperation(
        busyChinese: '正在检查技能回收计划。',
        busyEnglish: 'Checking the skill trash plan.',
        failureChinese: '技能回收计划失败。',
        failureEnglish: 'The skill trash plan failed.',
        failureCode: 'skill_delete_plan_failed',
        action: () async {
          plan = null;
          actionResult = null;
          plan = await _service.plan(skillId: skillId, path: path);
          actionResult = plan;
          reportStatus(
            SkillHubStatusUpdate(
              chinese: '已生成 $skillId 的回收计划，请确认后执行。',
              english:
                  'Prepared the trash plan for $skillId. Confirm it to apply.',
            ),
          );
        },
      );

  Future<void> apply({
    required String skillId,
    required String path,
    required String confirmation,
  }) => runOperation(
    busyChinese: '正在将技能移入系统回收站。',
    busyEnglish: 'Moving the skill to the system trash.',
    failureChinese: '技能移入系统回收站失败。',
    failureEnglish: 'Moving the skill to the system trash failed.',
    failureCode: 'skill_delete_apply_failed',
    action: () async {
      actionResult = null;
      actionResult = await _service.apply(
        skillId: skillId,
        path: path,
        confirmation: confirmation,
      );
      reportStatus(
        SkillHubStatusUpdate(
          chinese: '已将 $skillId 移入系统回收站。',
          english: 'Moved $skillId to the system trash.',
        ),
      );
    },
  );
}
