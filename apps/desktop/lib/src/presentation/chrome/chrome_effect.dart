import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';

sealed class ChromeEffect {
  const ChromeEffect({this.trace});

  final TraceContext? trace;
}

final class ChromeDestinationReselected extends ChromeEffect {
  const ChromeDestinationReselected(this.destination, {super.trace});

  final ClientSection destination;
}

final class ChromeSearchRequested extends ChromeEffect {
  const ChromeSearchRequested({super.trace});
}

final class ChromeNotificationsRequested extends ChromeEffect {
  const ChromeNotificationsRequested({super.trace});
}
