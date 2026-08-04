import 'package:licoup/src/application/features/skill_hub/controller/skill_usage_controller.dart';
import 'package:licoup/src/application/features/skill_hub/services/skill_usage_service.dart';
import 'package:licoup/src/contracts/skill_usage.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('usage controller owns only the selected local window report', () async {
    final controller = SkillUsageController(
      service: SkillUsageService(gateway: _Gateway()),
      onStatus: (_) {},
    );
    addTearDown(controller.dispose);

    await controller.load(days: 7, agent: 'codex', skillId: 'review');
    expect(controller.report?['windowDays'], 7);
  });

  test('report parsing joins per-skill totals by normalized id', () {
    final report = <String, dynamic>{
      'totalInvocations': 7,
      'allTimeInvocations': 42,
      'bySkill': [
        {'skillId': 'myskill', 'count': 7},
      ],
      'totalsBySkill': [
        {'skillId': 'myskill', 'count': 42},
        {'skillId': 'review', 'count': 3},
        {'skillId': '', 'count': 9},
        {'skillId': 'zero', 'count': 0},
      ],
    };

    expect(normalizeSkillUsageId('MySkill'), 'myskill');
    expect(normalizeSkillUsageId('  Code Review!  '), 'code-review');
    expect(skillUsageTotalsBySkill(report)['myskill'], 42);
    expect(skillUsageTotalsBySkill(report)['review'], 3);
    expect(skillUsageTotalsBySkill(report), hasLength(2));
    expect(skillUsageWindowedBySkill(report)['myskill'], 7);
    expect(skillUsageTotalsBySkill(null), isEmpty);
    expect(skillUsageWindowedBySkill(const {}), isEmpty);
  });

  test('loadCounts scans once per cooldown', () async {
    final gateway = _Gateway();
    final controller = SkillUsageController(
      service: SkillUsageService(gateway: gateway),
      onStatus: (_) {},
    );
    addTearDown(controller.dispose);

    await controller.loadCounts();
    expect(gateway.scanCalls, 1);
    expect(gateway.reportDays, 30);
    expect(skillUsageTotalsBySkill(controller.report)['review'], 4);
    expect(controller.lastErrorCode, isEmpty);

    // A second refresh inside the cooldown reuses the incremental backfill
    // instead of rescanning.
    await controller.loadCounts();
    expect(gateway.scanCalls, 1);
  });

  test('loadCounts keeps scan and report failures silent', () async {
    final gateway = _Gateway()..failScan = true;
    final controller = SkillUsageController(
      service: SkillUsageService(gateway: gateway),
      onStatus: (_) {},
      scanCooldownInterval: Duration.zero,
    );
    addTearDown(controller.dispose);

    await controller.loadCounts();
    expect(gateway.scanCalls, 1);
    expect(controller.report, isNotNull);
    expect(controller.lastErrorCode, isEmpty);

    gateway.failReport = true;
    await controller.loadCounts();
    expect(gateway.scanCalls, 2);
    expect(controller.lastErrorCode, isEmpty);
  });
}

class _Gateway implements SkillUsageGateway {
  int scanCalls = 0;
  int reportDays = 0;
  bool failScan = false;
  bool failReport = false;

  @override
  Future<Map<String, dynamic>> reportSkillUsage({
    int days = 30,
    String agent = '',
    String skillId = '',
  }) async {
    if (failReport) {
      throw StateError('report failed');
    }
    reportDays = days;
    return {
      'ok': true,
      'windowDays': days,
      'totalInvocations': 4,
      'allTimeInvocations': 4,
      'bySkill': const [],
      'totalsBySkill': const [
        {'skillId': 'review', 'count': 4},
      ],
    };
  }

  @override
  Future<Map<String, dynamic>> scanSkillUsage({
    String agent = '',
    bool forceRefresh = false,
  }) async {
    scanCalls += 1;
    if (failScan) {
      throw StateError('scan failed');
    }
    return {'ok': true};
  }
}
