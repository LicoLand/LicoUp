import 'package:flutter/foundation.dart';
import 'package:flutter_client/src/application/features/skill_hub/controller/skill_hub_status.dart';

abstract class SkillOperationController extends ChangeNotifier {
  SkillOperationController({required SkillHubStatusSink onStatus})
    : _onStatus = onStatus;

  final SkillHubStatusSink _onStatus;

  bool busy = false;
  String lastErrorCode = '';

  @protected
  void reportStatus(SkillHubStatusUpdate update) => _onStatus(update);

  @protected
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
    notifyListeners();
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
      notifyListeners();
    }
  }
}
