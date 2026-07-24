import 'package:licoup/src/application/features/skill_hub/controller/skill_hub_status.dart';
import 'package:licoup/src/application/features/skill_hub/controller/skill_operation_controller.dart';
import 'package:licoup/src/application/features/skill_hub/services/skill_usage_service.dart';

class SkillUsageController extends SkillOperationController {
  SkillUsageController({
    required SkillUsageService service,
    required super.onStatus,
  }) : _service = service;

  final SkillUsageService _service;

  Map<String, dynamic>? report;

  Future<void> load({int days = 30, String agent = '', String skillId = ''}) =>
      runOperation(
        busyChinese: '正在读取本机技能用量。',
        busyEnglish: 'Reading local skill usage.',
        failureChinese: '技能用量统计失败。',
        failureEnglish: 'Loading skill usage failed.',
        failureCode: 'skill_usage_report_failed',
        action: () async {
          report = await _service.report(
            days: days,
            agent: agent,
            skillId: skillId,
          );
          reportStatus(
            SkillHubStatusUpdate(
              chinese: '已统计最近 $days 天的技能调用频率。',
              english:
                  'Loaded skill invocation frequency for the last $days days.',
            ),
          );
        },
      );
}
