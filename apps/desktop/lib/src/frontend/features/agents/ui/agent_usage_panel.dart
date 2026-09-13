import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:licoup/src/contracts/agent_usage_models.dart';

import 'package:licoup/src/frontend/binding/projection_builder.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_usage_panel_widgets.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_usage_summary_widgets.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/frontend/shared/ui/lico_pane_scaffold.dart';
import 'package:licoup/src/presentation/monitoring/monitoring_binding.dart';
import 'package:licoup/src/presentation/monitoring/monitoring_intent.dart';
import 'package:licoup/src/presentation/monitoring/monitoring_projection.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

class AgentUsagePanel extends StatefulWidget {
  const AgentUsagePanel({
    super.key,
    required this.binding,
    this.autoLoad = true,
  });

  final MonitoringBinding binding;
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
    final strings = LicoStrings.of(context);
    return ProjectionBuilder<MonitoringProjection, _UsageView>(
      source: widget.binding.projection,
      select: _UsageView.new,
      // The standard feature-page structure: pane title bar (统计面板 +
      // refresh) above, usage charts as the content body below.
      builder: (context, projection) => LicoPaneScaffold(
        title: strings.statsPanel,
        refreshTooltip: strings.refreshUsage,
        onRefresh: projection.refreshing
            ? null
            : () => widget.binding.intents.send(const RefreshMonitoring()),
        refreshing: projection.refreshing,
        refreshButtonKey: const Key('agent-usage-refresh'),
        body:
            !projection.hasUsage &&
                projection.phase == PresentationPhase.loading
            ? const AgentUsageLoadingState()
            : !projection.hasUsage &&
                  projection.phase == PresentationPhase.failed
            ? Center(
                child: Text(
                  strings.usageLoadFailed,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: context.licoColors.textMuted),
                ),
              )
            : SingleChildScrollView(
                primary: false,
                padding: EdgeInsets.zero,
                child: AgentUsageCharts(
                  report: projection.report,
                  detectedAgentIds: projection.detectedAgentIds,
                  windowDays: projection.historyDays,
                  windowBusy: projection.refreshing,
                  onWindowChanged: (days) => widget.binding.intents.send(
                    SetMonitoringHistoryDays(days),
                  ),
                ),
              ),
      ),
    );
  }
}

/// Quota and diagnostics arrivals do not rebuild the usage chart subtree.
final class _UsageView {
  _UsageView(MonitoringProjection projection)
    : report = projection.report,
      historyDays = projection.historyDays,
      refreshing = projection.refreshing,
      phase = projection.phase,
      detectedAgentIds = {
        for (final target in projection.detectedTargets)
          if (target.status != 'not-detected') target.target,
      };

  final AgentUsageReport? report;
  final int historyDays;
  final bool refreshing;
  final PresentationPhase phase;
  final Set<String> detectedAgentIds;

  bool get hasUsage =>
      (report?.totalTokens ?? 0) > 0 ||
      (report?.agents.any(
            (agent) => agent.sessionCount > 0 || agent.messageCount > 0,
          ) ??
          false);

  @override
  bool operator ==(Object other) =>
      other is _UsageView &&
      identical(report, other.report) &&
      historyDays == other.historyDays &&
      refreshing == other.refreshing &&
      phase == other.phase &&
      setEquals(detectedAgentIds, other.detectedAgentIds);

  @override
  int get hashCode => Object.hash(
    report,
    historyDays,
    refreshing,
    phase,
    Object.hashAllUnordered(detectedAgentIds),
  );
}
