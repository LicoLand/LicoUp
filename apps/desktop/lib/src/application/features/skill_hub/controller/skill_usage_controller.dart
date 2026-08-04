import 'package:licoup/src/application/features/skill_hub/controller/skill_hub_status.dart';
import 'package:licoup/src/application/features/skill_hub/controller/skill_operation_controller.dart';
import 'package:licoup/src/application/features/skill_hub/services/skill_usage_service.dart';

class SkillUsageController extends SkillOperationController {
  SkillUsageController({
    required SkillUsageService service,
    required super.onStatus,
    this.scanCooldownInterval = scanCooldown,
  }) : _service = service;

  final SkillUsageService _service;

  /// Minimum interval between two history backfill scans. The scan is
  /// incremental (watermarks) but not free on first run, so panel refreshes
  /// share one throttled scan instead of scanning every time.
  static const Duration scanCooldown = Duration(minutes: 5);

  final Duration scanCooldownInterval;

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

  Future<void> scan({String agent = '', bool forceRefresh = false}) =>
      runOperation(
        busyChinese: '正在回填本机技能调用历史。',
        busyEnglish: 'Backfilling local skill invocation history.',
        failureChinese: '技能调用历史回填失败。',
        failureEnglish: 'Backfilling skill invocation history failed.',
        failureCode: 'skill_usage_scan_failed',
        action: () async {
          await _service.scan(agent: agent, forceRefresh: forceRefresh);
        },
      );

  DateTime? _lastScanAt;
  bool _countsLoading = false;

  /// Background scan + report refresh for card invocation counts. Never
  /// blocks the panel and never surfaces an error state: scan or report
  /// failures simply leave the previous counts in place.
  Future<void> loadCounts({int days = 30}) async {
    if (_countsLoading) {
      return;
    }
    _countsLoading = true;
    try {
      final now = DateTime.now();
      final lastScan = _lastScanAt;
      if (lastScan == null ||
          now.difference(lastScan) >= scanCooldownInterval) {
        try {
          await _service.scan();
          _lastScanAt = now;
        } catch (_) {
          // A failed scan leaves earlier backfills usable; report anyway.
        }
      }
      try {
        report = await _service.report(days: days);
      } catch (_) {
        // Invocation counts are an enhancement, never a panel error.
      }
    } finally {
      _countsLoading = false;
      notifyListeners();
    }
  }
}
