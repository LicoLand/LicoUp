import 'package:presentation_contract/presentation_contract.dart';

sealed class AgentsEffect {
  const AgentsEffect({this.trace});

  final TraceContext? trace;
}

final class AgentSelectionRejected extends AgentsEffect {
  const AgentSelectionRejected(this.reasonCode, {super.trace});

  final String reasonCode;
}

final class AgentWorkingDirectorySelectionRejected extends AgentsEffect {
  const AgentWorkingDirectorySelectionRejected(this.reasonCode, {super.trace});

  final String reasonCode;
}

final class AdaptiveFlywheelSaveCompleted extends AgentsEffect {
  const AdaptiveFlywheelSaveCompleted({super.trace});
}

final class AdaptiveFlywheelConfigurationSaved extends AgentsEffect {
  const AdaptiveFlywheelConfigurationSaved({super.trace});
}

final class AdaptiveFlywheelActionRejected extends AgentsEffect {
  const AdaptiveFlywheelActionRejected(this.reasonCode, {super.trace});

  final String reasonCode;
}
