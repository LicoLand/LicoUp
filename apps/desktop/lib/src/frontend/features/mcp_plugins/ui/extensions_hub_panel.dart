import 'package:flutter/material.dart';

import 'package:flutter_client/src/application/controller/client_controller.dart';
import 'package:flutter_client/src/frontend/features/mcp_plugins/ui/mcp_plugins_panel.dart';
import 'package:flutter_client/src/frontend/features/skill_hub/ui/skill_hub_panel.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

/// Combined MCP Plugins + Skill Hub surface under one shell section.
class ExtensionsHubPanel extends StatefulWidget {
  const ExtensionsHubPanel({super.key, required this.controller});

  final ClientController controller;

  @override
  State<ExtensionsHubPanel> createState() => _ExtensionsHubPanelState();
}

class _ExtensionsHubPanelState extends State<ExtensionsHubPanel>
    with SingleTickerProviderStateMixin {
  late final TabController _tabs;

  @override
  void initState() {
    super.initState();
    _tabs = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabs.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return Column(
      children: [
        Material(
          color: colors.background,
          child: TabBar(
            key: const Key('extensions-hub-tabs'),
            controller: _tabs,
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            labelColor: colors.text,
            unselectedLabelColor: colors.textMuted,
            indicatorColor: colors.primaryStrong,
            dividerColor: colors.line.withAlpha(80),
            labelStyle: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
            unselectedLabelStyle: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
            tabs: [
              Tab(text: strings.mcpPlugins),
              Tab(text: strings.skillHub),
            ],
          ),
        ),
        Expanded(
          child: TabBarView(
            controller: _tabs,
            children: [
              McpPluginsPanel(controller: widget.controller),
              SkillHubPanel(controller: widget.controller),
            ],
          ),
        ),
      ],
    );
  }
}
