import 'package:licoup/src/application/state/application_signal.dart';

import 'package:licoup/src/application/features/skill_hub/controller/skill_hub_status.dart';

abstract class SkillOperationController extends ApplicationStateOwner {
  SkillOperationController({required SkillHubStatusSink onStatus})
    : _onStatus = onStatus;

  final SkillHubStatusSink _onStatus;

  bool busy = false;
  String lastErrorCode = '';

  void reportStatus(SkillHubStatusUpdate update) => _onStatus(update);

  Future<void> runOperation({
    required String busyChinese,
    required String busyEnglish,
    required String failureChinese,
    required String failureEnglish,
    required String failureCode,
    required Future<void> Function() action,
  }) async {
    if (busy) return;
    busy = true;
    lastErrorCode = '';
    reportStatus(
      SkillHubStatusUpdate(chinese: busyChinese, english: busyEnglish),
    );
    publishChange();
    try {
      await action();
    } catch (_) {
      lastErrorCode = failureCode;
      reportStatus(
        SkillHubStatusUpdate(
          chinese: failureChinese,
          english: failureEnglish,
          errorCode: failureCode,
        ),
      );
    } finally {
      busy = false;
      publishChange();
    }
  }
}
