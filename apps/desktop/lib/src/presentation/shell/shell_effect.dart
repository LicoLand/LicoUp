import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';

sealed class ShellEffect {
  const ShellEffect({this.trace});

  final TraceContext? trace;
}

final class ShellDestinationReselected extends ShellEffect {
  const ShellDestinationReselected(this.destination, {super.trace});

  final ClientSection destination;
}
