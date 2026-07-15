import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import 'package:flutter_client/src/application/controller/client_controller.dart';
import 'package:flutter_client/src/contracts/agent_usage_models.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_usage_pricing.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

part 'agent_usage_panel_widgets.dart';

class AgentUsagePanel extends StatefulWidget {
  const AgentUsagePanel({
    super.key,
    required this.controller,
    this.autoLoad = true,
  });

  final ClientController controller;
  final bool autoLoad;

  @override
  State<AgentUsagePanel> createState() => _AgentUsagePanelState();
}

class _AgentUsagePanelState extends State<AgentUsagePanel>
    with WidgetsBindingObserver {
  ClientController get controller => widget.controller;

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
        oldWidget.controller != widget.controller ||
        oldWidget.autoLoad != widget.autoLoad;
    if (!pollingOwnerChanged) {
      return;
    }
    if (oldWidget.autoLoad) {
      oldWidget.controller.stopAgentUsagePolling();
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
      controller.stopAgentUsagePolling();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    if (widget.autoLoad) {
      controller.stopAgentUsagePolling();
    }
    super.dispose();
  }

  void _startAutomaticRefresh() {
    if (!_appIsActive) {
      return;
    }
    _requestUsageScan();
    controller.startAgentUsagePolling();
  }

  bool get _appIsActive {
    final lifecycleState = WidgetsBinding.instance.lifecycleState;
    return lifecycleState == null ||
        lifecycleState == AppLifecycleState.resumed;
  }

  void _requestUsageScan() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          !_appIsActive ||
          controller.agentUsageReport?.isFresh() == true) {
        return;
      }
      unawaited(controller.ensureAgentUsageLoadedAndFresh(limit: 20));
    });
  }

  @override
  Widget build(BuildContext context) {
    final report = controller.agentUsageReport;
    return SingleChildScrollView(
      primary: false,
      padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
      child: _UsageCharts(
        report: report,
        detectedAgentIds: {
          for (final target in controller.orderedConversationTargets(
            controller.scannedTargets,
          ))
            if (target.status != 'not-detected') target.target,
        },
      ),
    );
  }
}
