import 'package:flutter/material.dart';

import 'dart:async';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/frontend/features/skill_hub/ui/skill_hub_panel_catalog.dart';

export 'package:licoup/src/frontend/features/skill_hub/ui/skill_hub_panel_icon_picker.dart'
    show SkillCategoryIconBadge, resolveSkillIconColor, showSkillIconPicker;

class SkillHubPanel extends StatefulWidget {
  const SkillHubPanel({super.key, required this.controller});

  final ClientController controller;

  @override
  State<SkillHubPanel> createState() => _SkillHubPanelState();
}

class _SkillHubPanelState extends State<SkillHubPanel> {
  final TextEditingController _agentController = TextEditingController(
    text: 'codex',
  );
  String _categoryFilter = 'all';

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_handleControllerChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !widget.controller.isSkillHubBusy) {
        _refresh();
      }
    });
  }

  @override
  void didUpdateWidget(covariant SkillHubPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller == widget.controller) return;
    oldWidget.controller.removeListener(_handleControllerChanged);
    widget.controller.addListener(_handleControllerChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_handleControllerChanged);
    _agentController.dispose();
    super.dispose();
  }

  void _handleControllerChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: SkillCategoryFilter(
            selectedCategory: _categoryFilter,
            onChanged: (category) {
              setState(() => _categoryFilter = category);
            },
          ),
        ),
        SkillCollection(
          controller: widget.controller,
          selectedCategory: _categoryFilter,
        ),
      ],
    );
  }

  void _refresh() {
    // Invocation counts load in the background (throttled scan + report) and
    // never block or error the panel; cards update when the report arrives.
    unawaited(widget.controller.loadSkillUsageCounts());
    widget.controller.refreshSkillHub(_agentController.text.trim());
  }
}
