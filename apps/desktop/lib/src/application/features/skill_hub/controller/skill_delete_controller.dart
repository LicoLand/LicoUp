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

  Future<void> preview({
    required Iterable<String> agents,
    required String skillId,
    String installRoot = '',
  }) => runOperation(
    busyChinese: '正在检查多智能体技能删除计划。',
    busyEnglish: 'Checking the multi-agent skill deletion plan.',
    failureChinese: '技能删除计划失败。',
    failureEnglish: 'The skill deletion plan failed.',
    failureCode: 'skill_delete_plan_failed',
    action: () async {
      plan = await _service.plan(
        agents: agents,
        skillId: skillId,
        installRoot: installRoot,
      );
      actionResult = plan;
      reportStatus(
        SkillHubStatusUpdate(
          chinese: '已生成 $skillId 的删除计划，请确认后执行。',
          english:
              'Prepared the deletion plan for $skillId. Confirm it to apply.',
        ),
      );
    },
  );

  Future<void> apply({
    required Iterable<String> agents,
    required String skillId,
    required String confirmation,
    String installRoot = '',
  }) => runOperation(
    busyChinese: '正在执行已确认的技能删除。',
    busyEnglish: 'Applying the confirmed skill deletion.',
    failureChinese: '技能删除失败。',
    failureEnglish: 'The skill deletion failed.',
    failureCode: 'skill_delete_apply_failed',
    action: () async {
      actionResult = await _service.apply(
        agents: agents,
        skillId: skillId,
        confirmation: confirmation,
        installRoot: installRoot,
      );
      reportStatus(
        SkillHubStatusUpdate(
          chinese: '已从所选智能体删除 $skillId。',
          english: 'Deleted $skillId from the selected agents.',
        ),
      );
    },
  );
}
