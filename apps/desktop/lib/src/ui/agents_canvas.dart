import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/future_client_controller.dart';
import 'agent_conversation_workspace.dart';
import 'agents_toolbar.dart';
import 'manual_target_dialog.dart';
import 'theme.dart';

class AgentsCanvas extends StatefulWidget {
  const AgentsCanvas({super.key, required this.controller});

  final FutureClientController controller;

  @override
  State<AgentsCanvas> createState() => _AgentsCanvasState();
}

class _AgentsCanvasState extends State<AgentsCanvas> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.controller.scanTargets();
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

        return Scaffold(
          backgroundColor: colors.background,
          body: LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < 720;
              final pagePadding = compact ? 16.0 : 24.0;
              return Padding(
                padding: EdgeInsets.all(pagePadding),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    AgentsToolbar(
                      scanning: scanning,
                      adding: adding,
                      onRescan: widget.controller.scanTargets,
                      onAddTarget: _showAddTargetDialog,
                    ),
                    SizedBox(height: compact ? 14 : 18),
                    Expanded(
                      child: AgentConversationWorkspace(
                        controller: widget.controller,
                        targets: targets,
                        scanning: scanning,
                        adding: adding,
                        onRescan: widget.controller.scanTargets,
                        onAddTarget: _showAddTargetDialog,
                        onInspect: widget.controller.inspectTarget,
                        onPlan: widget.controller.planTargetConfig,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
        );
      },
    );
  }

  Future<void> _showAddTargetDialog() async {
    final draft = await showDialog<ManualTargetDraft>(
      context: context,
      builder: (context) => const ManualTargetDialog(),
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
      ),
    );
  }
}
