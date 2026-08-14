import 'dart:async';

import 'package:flutter/material.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_workspace.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_port.dart';
import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/shared/platform/client_platform.dart';
import 'package:licoup/src/frontend/features/targets/ui/manual_target_dialog.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/mobile_agents_home.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

class AgentsCanvas extends StatefulWidget {
  const AgentsCanvas({super.key, required this.controller, this.agentsHomeKey});

  final ClientController controller;
  final GlobalKey<MobileAgentsHomeState>? agentsHomeKey;

  @override
  State<AgentsCanvas> createState() => _AgentsCanvasState();
}

class _AgentsCanvasState extends State<AgentsCanvas> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!widget.controller.mobileClientRuntimePlatform) {
        // Cache paints immediately; only probe adapters that are still unknown
        // unless the user explicitly refreshes with progress.
        unawaited(
          widget.controller.scanTargets(
            showProgress: widget.controller.scannedTargets.isEmpty,
            forceRescanKnown: false,
          ),
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final colors = context.licoColors;
        final scanning = widget.controller.isScanningTargets;
        final adding = widget.controller.isAddingTarget;
        final targets = widget.controller.scannedTargets
            .where((target) => target.visibleInClient)
            .toList(growable: false);
        final mobileClient =
            widget.controller.mobileClientRuntimePlatform ||
            isMobileClientPlatform(context);
        final allowManualTargetActions = !mobileClient;

        if (mobileClient) {
          return Scaffold(
            backgroundColor: colors.background,
            body: MobileAgentsHome(
              key: widget.agentsHomeKey,
              controller: widget.controller,
            ),
          );
        }

        final agentsPresentation = LayoutDestinationPresentationScope.maybeOf(
          context,
        )?.agents;
        final chrome = LayoutChromePortScope.maybeOf(context);
        return Scaffold(
          backgroundColor:
              agentsPresentation?.canvasColor(context.layoutPalette) ??
              colors.background,
          body: AgentConversationWorkspace(
            controller: widget.controller,
            targets: targets,
            scanning: scanning,
            adding: adding,
            onAddTarget: _showAddTargetDialog,
            onSearch: chrome == null
                ? null
                : () => unawaited(chrome.openGlobalSearch(context)),
            allowManualTargetActions: allowManualTargetActions,
          ),
        );
      },
    );
  }

  Future<void> _showAddTargetDialog() async {
    final strings = LicoStrings.of(context);
    final draft = await showDialog<ManualTargetDraft>(
      context: context,
      builder: (context) => ManualTargetDialog(
        onOpenDirectory: (path) =>
            widget.controller.openDirectoryPath(path, caption: strings.manual),
      ),
    );
    if (draft == null) {
      return;
    }
    unawaited(
      widget.controller.addManualTarget(
        target: draft.target,
        configPath: draft.configPath,
        binaryPath: draft.binaryPath,
        historyRoot: draft.historyRoot,
        location: draft.location,
        runtimeConnection: draft.runtimeConnection,
      ),
    );
  }
}
