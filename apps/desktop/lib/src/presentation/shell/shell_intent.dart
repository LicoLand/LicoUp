import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';

sealed class ShellIntent {
  const ShellIntent({this.trace});

  final TraceContext? trace;
}

final class SelectShellDestination extends ShellIntent {
  const SelectShellDestination(this.destination, {super.trace});

  final ClientSection destination;
}

final class UpdateShellLayoutEnvironment extends ShellIntent {
  const UpdateShellLayoutEnvironment(this.environment, {super.trace});

  final LayoutEnvironment environment;
}

final class OpenShellAgent extends ShellIntent {
  const OpenShellAgent(this.agentId, {super.trace});

  final String agentId;
}
