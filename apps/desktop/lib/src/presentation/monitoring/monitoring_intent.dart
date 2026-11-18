import 'package:presentation_contract/presentation_contract.dart';

sealed class MonitoringIntent {
  const MonitoringIntent({this.trace});

  final TraceContext? trace;
}

final class RefreshMonitoring extends MonitoringIntent {
  const RefreshMonitoring({super.trace});
}

final class StartAutomaticMonitoring extends MonitoringIntent {
  const StartAutomaticMonitoring({super.trace});
}

final class StopAutomaticMonitoring extends MonitoringIntent {
  const StopAutomaticMonitoring({super.trace});
}

final class SetMonitoringHistoryDays extends MonitoringIntent {
  const SetMonitoringHistoryDays(this.days, {super.trace});

  final int days;
}
