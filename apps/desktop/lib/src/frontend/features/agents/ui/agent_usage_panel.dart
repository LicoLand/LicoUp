import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/binding/projection_builder.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_usage_panel_widgets.dart';
import 'package:licoup/src/presentation/monitoring/monitoring_binding.dart';
import 'package:licoup/src/presentation/monitoring/monitoring_intent.dart';
import 'package:licoup/src/presentation/monitoring/monitoring_projection.dart';

class AgentUsagePanel extends StatefulWidget {
  const AgentUsagePanel({
    super.key,
    required this.binding,
    required this.onExit,
    this.autoLoad = true,
  });

  final MonitoringBinding binding;
  final VoidCallback onExit;
  final bool autoLoad;

  @override
  State<AgentUsagePanel> createState() => _AgentUsagePanelState();
}

class _AgentUsagePanelState extends State<AgentUsagePanel>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.autoLoad) {
      _startAutomaticRefresh();
    }
  }

  @override
  void didUpdateWidget(covariant AgentUsagePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    final pollingOwnerChanged =
        !identical(oldWidget.binding, widget.binding) ||
        oldWidget.autoLoad != widget.autoLoad;
    if (!pollingOwnerChanged) {
      return;
    }
    if (oldWidget.autoLoad) {
      oldWidget.binding.intents.send(const StopAutomaticMonitoring());
    }
    if (widget.autoLoad) {
      _startAutomaticRefresh();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!widget.autoLoad) {
      return;
    }
    if (state == AppLifecycleState.resumed) {
      _startAutomaticRefresh();
    } else {
      widget.binding.intents.send(const StopAutomaticMonitoring());
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (widget.autoLoad) {
      widget.binding.intents.send(const StopAutomaticMonitoring());
    }
    super.dispose();
  }

  void _startAutomaticRefresh() {
    if (!_appIsActive) {
      return;
    }
    widget.binding.intents.send(const StartAutomaticMonitoring());
  }

  bool get _appIsActive {
    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    return lifecycleState == null ||
        lifecycleState == AppLifecycleState.resumed;
  }

  @override
  Widget build(BuildContext context) {
    return ProjectionBuilder<MonitoringProjection, MonitoringProjection>(
      source: widget.binding.projection,
      select: (projection) => projection,
      builder: (context, projection) => SingleChildScrollView(
        primary: false,
        padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
        child: AgentUsageCharts(
          report: projection.report,
          detectedAgentIds: {
            for (final target in projection.detectedTargets)
              if (target.status != 'not-detected') target.target,
          },
          windowDays: projection.historyDays,
          windowBusy: projection.refreshing,
          onWindowChanged: (days) =>
              widget.binding.intents.send(SetMonitoringHistoryDays(days)),
          onExit: widget.onExit,
        ),
      ),
    );
  }
}
