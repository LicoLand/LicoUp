import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/future_client_controller.dart';
import '../models/future_client_models.dart';
import '../services/activity_snapshot_service.dart';
import 'activity_panel.dart';
import 'agents_canvas.dart';
import 'local_runtime_panel.dart';
import 'mcp_plugins_panel.dart';
import 'model_forwarding_panel.dart';
import 'mobile_relay_panel.dart';
import 'settings_panel.dart';
import 'shell_navigation.dart';
import 'skill_hub_panel.dart';

class ClientShell extends StatefulWidget {
  const ClientShell({
    super.key,
    required this.controller,
    this.activitySnapshots = const ActivitySnapshotService(),
  });

  final FutureClientController controller;
  final ActivitySnapshotService activitySnapshots;

  @override
  State<ClientShell> createState() => _ClientShellState();
}

class _ClientShellState extends State<ClientShell> {
  late Future<ActivitySnapshotState> _activityFuture;

  FutureClientController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _activityFuture = _loadActivitySnapshotState();
    if (controller.scannedTargets.isEmpty) {
      unawaited(controller.scanTargets());
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return Scaffold(
          body: SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final compactNavigation = constraints.maxWidth < 900;
                return Row(
                  children: [
                    ShellSidebar(
                      current: controller.currentSection,
                      compact: compactNavigation,
                      onSelect: controller.selectSection,
                    ),
                    Expanded(
                      child: Column(
                        children: [
                          ShellTopBar(section: controller.currentSection),
                          Expanded(
                            child:
                                controller.currentSection ==
                                    FutureClientSection.agents
                                ? _sectionBody()
                                : Padding(
                                    padding: const EdgeInsets.all(20),
                                    child: _sectionBody(),
                                  ),
                          ),
                          ShellStatusBar(controller: controller),
                        ],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        );
      },
    );
  }

  Widget _sectionBody() {
    return switch (controller.currentSection) {
      FutureClientSection.agents => AgentsCanvas(controller: controller),
      FutureClientSection.mcpPlugins => McpPluginsPanel(controller: controller),
      FutureClientSection.skillHub => SkillHubPanel(controller: controller),
      FutureClientSection.modelForwarding => ModelForwardingPanel(
        controller: controller,
      ),
      FutureClientSection.localRuntime => LocalRuntimePanel(
        controller: controller,
      ),
      FutureClientSection.mobileRelay => MobileRelayPanel(
        controller: controller,
      ),
      FutureClientSection.activity => FutureBuilder<ActivitySnapshotState>(
        future: _activityFuture,
        builder: (context, snapshot) {
          return ActivityPanel(
            state: snapshot.data ?? ActivitySnapshotState.empty(),
            onRefresh: () {
              setState(() {
                _activityFuture = _loadActivitySnapshotState();
              });
            },
            onRestoreSnapshot: (snapshotId) {
              unawaited(_restoreSnapshot(snapshotId));
            },
          );
        },
      ),
      FutureClientSection.settings => SettingsPanel(controller: controller),
    };
  }

  Future<ActivitySnapshotState> _loadActivitySnapshotState() {
    return widget.activitySnapshots.load(controller.agentService);
  }

  Future<void> _restoreSnapshot(String snapshotId) async {
    await controller.restoreSnapshot(snapshotId);
    if (!mounted) {
      return;
    }
    setState(() {
      _activityFuture = _loadActivitySnapshotState();
    });
  }
}
