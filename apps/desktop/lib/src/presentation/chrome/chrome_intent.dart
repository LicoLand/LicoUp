import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';

sealed class ChromeIntent {
  const ChromeIntent({this.trace});

  final TraceContext? trace;
}

final class SelectChromeDestination extends ChromeIntent {
  const SelectChromeDestination(this.destination, {super.trace});

  final ClientSection destination;
}

final class SetAuxiliaryPanelOpen extends ChromeIntent {
  const SetAuxiliaryPanelOpen(this.open, {super.trace});

  final bool open;
}

final class ShowChromeSearch extends ChromeIntent {
  const ShowChromeSearch({super.trace});
}

final class ShowChromeNotifications extends ChromeIntent {
  const ShowChromeNotifications({super.trace});
}

final class DismissChromeNotification extends ChromeIntent {
  const DismissChromeNotification(this.notificationId, {super.trace});

  final String notificationId;
}

final class RecoverChromeGateway extends ChromeIntent {
  const RecoverChromeGateway({super.trace});
}

final class OpenChromeAgentConversation extends ChromeIntent {
  const OpenChromeAgentConversation({
    required this.agentId,
    required this.sessionId,
    required this.nativeSessionId,
    super.trace,
  });

  final String agentId;
  final String sessionId;
  final String nativeSessionId;
}
