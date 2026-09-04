import 'dart:async';

import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/binding/projection_builder.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_workspace.dart';
import 'package:licoup/src/frontend/features/agents/ui/mobile_widgets_page.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/mobile_agents_home.dart';
import 'package:licoup/src/frontend/features/targets/ui/manual_target_dialog.dart';
import 'package:licoup/src/frontend/layout/layout_agents_strategy.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_port.dart';
import 'package:licoup/src/frontend/shared/platform/client_platform.dart';
import 'package:licoup/src/frontend/shared/ui/agent_brand_icon.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/presentation/agents/agents_binding.dart';
import 'package:licoup/src/presentation/agents/agents_intent.dart';
import 'package:licoup/src/presentation/agents/agents_projection.dart';
import 'package:licoup/src/presentation/conversation/conversation_binding.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_binding.dart';
import 'package:licoup/src/presentation/monitoring/monitoring_binding.dart';
import 'package:licoup/src/presentation/targets/targets_binding.dart';

class AgentsCanvas extends StatefulWidget {
  const AgentsCanvas({
    super.key,
    required this.agents,
    required this.conversation,
    required this.relay,
    required this.monitoring,
    required this.targets,
    required this.onSelectDestination,
    this.agentsHomeKey,
  });

  final AgentsBinding agents;
  final ConversationBinding conversation;
  final MobileRelayBinding relay;
  final MonitoringBinding monitoring;
  final TargetsBinding targets;
  final ValueChanged<ClientSection> onSelectDestination;
  final GlobalKey<MobileAgentsHomeState>? agentsHomeKey;

  @override
  State<AgentsCanvas> createState() => _AgentsCanvasState();
}

class _AgentsCanvasState extends State<AgentsCanvas> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final projection = widget.agents.projection.current;
      if (!projection.mobileRuntime && !projection.scanning) {
        widget.agents.intents.send(
          ScanAgents(
            showProgress: projection.targetDetails.isEmpty,
            forceRescanKnown: false,
          ),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return ProjectionBuilder<AgentsProjection, AgentsProjection>(
      source: widget.agents.projection,
      select: (projection) => projection,
      builder: (context, projection) {
        final colors = context.licoColors;
        final mobileClient =
            projection.mobileRuntime || isMobileClientPlatform(context);
        if (mobileClient) {
          return Scaffold(
            backgroundColor: colors.background,
            body: MobileAgentsHome(
              key: widget.agentsHomeKey,
              agents: widget.agents,
              relay: widget.relay,
              conversationContentBuilder: (context, _) =>
                  AgentConversationWorkspace(
                    agents: widget.agents,
                    conversation: widget.conversation,
                    relay: widget.relay,
                    onAddTarget: _showAddTargetDialog,
                    onSelectDestination: widget.onSelectDestination,
                    allowManualTargetActions: false,
                  ),
              configurationContentBuilder: (context, _) =>
                  MobileWidgetsPage(binding: widget.monitoring),
              iconBuilder:
                  (
                    context,
                    target, {
                    required selected,
                    required size,
                    required iconSize,
                  }) {
                    for (final detail in projection.targetDetails) {
                      if (detail.id == target.id ||
                          detail.target == target.id) {
                        return AgentBrandIcon(
                          target: detail,
                          selected: selected,
                          detected: target.available,
                          size: size,
                          iconSize: iconSize,
                        );
                      }
                    }
                    return Icon(
                      target.available
                          ? Icons.smart_toy_outlined
                          : Icons.extension_outlined,
                      size: iconSize,
                    );
                  },
            ),
          );
        }

        final strategy = LayoutAgentsStrategyScope.maybeOf(context);
        final chrome = LayoutChromePortScope.maybeOf(context);
        return Scaffold(
          backgroundColor:
              strategy.sidebarStyle == AgentsSidebarStyle.flatRecencyList
              ? Colors.transparent
              : colors.background,
          body: AgentConversationWorkspace(
            agents: widget.agents,
            conversation: widget.conversation,
            relay: widget.relay,
            onAddTarget: _showAddTargetDialog,
            onSelectDestination: widget.onSelectDestination,
            onSearch: chrome == null
                ? null
                : () => unawaited(chrome.openGlobalSearch(context)),
          ),
        );
      },
    );
  }

  Future<void> _showAddTargetDialog() async {
    final draft = await showDialog<ManualTargetDraft>(
      context: context,
      builder: (context) => ManualTargetDialog(
        options: widget.targets.projection.current.manualTargetOptions,
      ),
    );
    if (draft == null) return;
    widget.agents.intents.send(
      AddManualAgent(
        command: draft.target,
        configPath: draft.configPath,
        binaryPath: draft.binaryPath,
        historyRoot: draft.historyRoot,
        location: draft.location,
        runtimeConnection: draft.runtimeConnection,
      ),
    );
  }
}
