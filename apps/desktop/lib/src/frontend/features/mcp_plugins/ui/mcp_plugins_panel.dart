import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

import 'package:flutter_client/src/application/controller/client_controller.dart';
import 'package:flutter_client/src/contracts/target_candidate.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/shared/ui/agent_brand_icon.dart';
import 'package:flutter_client/src/frontend/shared/ui/apple_buttons.dart';
import 'package:flutter_client/src/frontend/shared/ui/directory_path_field.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

part 'mcp_plugins_panel_widgets.dart';

class McpPluginsPanel extends StatelessWidget {
  const McpPluginsPanel({super.key, required this.controller});

  final ClientController controller;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final targets = controller.scannedTargets
        .where(_isMcpPluginTarget)
        .toList(growable: false);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                strings.mcpPlugins,
                style: TextStyle(
                  color: colors.text,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.2,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                strings.pluginHubSubtitle,
                style: TextStyle(
                  color: colors.textMuted,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  height: 1.35,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                targets.isEmpty
                    ? strings.noScannedAgents
                    : strings.scannedAgentCount(targets.length),
                style: TextStyle(
                  color: colors.textMuted,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: targets.isEmpty
              ? const _McpPluginsEmptyState()
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final width = constraints.maxWidth;
                    final crossAxisCount = width >= 1100
                        ? 3
                        : width >= 720
                        ? 2
                        : 1;
                    return GridView.builder(
                      key: const Key('mcp-plugins-agent-grid'),
                      padding: const EdgeInsets.fromLTRB(18, 8, 18, 20),
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: crossAxisCount,
                        crossAxisSpacing: 14,
                        mainAxisSpacing: 14,
                        mainAxisExtent: 204,
                      ),
                      itemCount: targets.length,
                      itemBuilder: (context, index) {
                        final target = targets[index];
                        return _AgentPluginCard(
                          target: target,
                          mcpStatus:
                              controller.mcpPluginStatuses[target.target],
                          busy: controller.isMcpPluginBusy(target.target),
                          onConfigure: () => showAgentPluginConfigPopup(
                            context,
                            controller: controller,
                            target: target,
                          ),
                        );
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }
}

/// Opens MCP/ACP configuration as a floating card for one agent.
Future<void> showAgentPluginConfigPopup(
  BuildContext context, {
  required ClientController controller,
  required TargetCandidate target,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    builder: (context) =>
        _AgentPluginConfigDialog(controller: controller, targetId: target.id),
  );
}
