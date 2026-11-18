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

final class AcativaSaveCompleted extends AgentsEffect {
  const AcativaSaveCompleted({super.trace});
}

final class AcativaActionRejected extends AgentsEffect {
  const AcativaActionRejected(this.reasonCode, {super.trace});

  final String reasonCode;
}
