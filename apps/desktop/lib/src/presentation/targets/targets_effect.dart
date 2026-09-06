import 'package:presentation_contract/presentation_contract.dart';

sealed class TargetsEffect {
  const TargetsEffect({this.trace});

  final TraceContext? trace;
}

final class TargetInspectionReady extends TargetsEffect {
  const TargetInspectionReady(this.targetId, this.summary, {super.trace});

  final String targetId;
  final String summary;
}

final class TargetActionRejected extends TargetsEffect {
  const TargetActionRejected(this.targetId, this.reasonCode, {super.trace});

  final String targetId;
  final String reasonCode;
}
