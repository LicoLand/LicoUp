import 'package:presentation_contract/presentation_contract.dart';

sealed class TargetsIntent {
  const TargetsIntent({this.trace});

  final TraceContext? trace;
}

final class ScanTargets extends TargetsIntent {
  const ScanTargets({this.force = false, super.trace});

  final bool force;
}

final class AddManualTarget extends TargetsIntent {
  const AddManualTarget({
    required this.targetId,
    this.configPath = '',
    this.binaryPath = '',
    this.historyRoot = '',
    this.location = 'local',
    this.host = '',
    this.port,
    this.user = '',
    this.remoteExecutable = '',
    this.workingDirectory = '',
    this.runtimeProtocol = '',
    super.trace,
  });

  final String targetId;
  final String configPath;
  final String binaryPath;
  final String historyRoot;
  final String location;
  final String host;
  final int? port;
  final String user;
  final String remoteExecutable;
  final String workingDirectory;
  final String runtimeProtocol;
}

final class SelectTarget extends TargetsIntent {
  const SelectTarget(this.targetId, {super.trace});

  final String targetId;
}

final class ToggleTargetPinned extends TargetsIntent {
  const ToggleTargetPinned(this.targetId, {super.trace});

  final String targetId;
}

final class InspectTarget extends TargetsIntent {
  const InspectTarget(this.targetId, {super.trace});

  final String targetId;
}
