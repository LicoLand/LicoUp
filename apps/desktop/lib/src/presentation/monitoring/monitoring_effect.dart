import 'package:presentation_contract/presentation_contract.dart';

sealed class MonitoringEffect {
  const MonitoringEffect({this.trace});

  final TraceContext? trace;
}

final class MonitoringRefreshRejected extends MonitoringEffect {
  const MonitoringRefreshRejected(this.reasonCode, {super.trace});

  final String reasonCode;
}
