import 'package:presentation_contract/presentation_contract.dart';

sealed class SettingsEffect {
  const SettingsEffect({this.trace});

  final TraceContext? trace;
}

final class ClientRestartRequired extends SettingsEffect {
  const ClientRestartRequired({super.trace});
}

final class DataHomeRelocationRequested extends SettingsEffect {
  const DataHomeRelocationRequested(this.destinationParent, {super.trace});

  final String destinationParent;
}

final class PreviousDataHomeCleanupRequested extends SettingsEffect {
  const PreviousDataHomeCleanupRequested(
    this.expectedPreviousRootPath, {
    super.trace,
  });

  final String expectedPreviousRootPath;
}

final class SettingsActionRejected extends SettingsEffect {
  const SettingsActionRejected(this.reasonCode, {super.trace});

  final String reasonCode;
}

final class ArchivedConversationRestoreCompleted extends SettingsEffect {
  const ArchivedConversationRestoreCompleted({
    required this.conversationId,
    required this.restored,
    super.trace,
  });

  final String conversationId;
  final bool restored;
}
