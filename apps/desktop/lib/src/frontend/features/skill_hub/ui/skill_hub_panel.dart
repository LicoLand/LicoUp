import 'package:flutter/material.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/frontend/features/skill_hub/ui/skill_hub_panel_catalog.dart';
import 'package:licoup/src/frontend/features/skill_hub/ui/skill_hub_panel_widgets.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

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
  final TextEditingController _urlController = TextEditingController();
  String _categoryFilter = 'all';
  OverlayEntry? _settingsEntry;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !widget.controller.isSkillHubBusy) {
        _refresh();
      }
    });
  }

  @override
  void dispose() {
    _closeSettingsDrawer(notify: false);
    _agentController.dispose();
    _urlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final colors = context.licoColors;
    final drawerOpen = _settingsEntry != null;

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Row(
            children: [
              Expanded(
                child: SkillCategoryFilter(
                  selectedCategory: _categoryFilter,
                  onChanged: (category) {
                    setState(() => _categoryFilter = category);
                  },
                ),
              ),
              Tooltip(
                message: drawerOpen
                    ? strings.hideSkillHubSettings
                    : strings.showSkillHubSettings,
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: _toggleSettingsDrawer,
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Icon(
                      drawerOpen ? Icons.settings : Icons.settings_outlined,
                      size: 18,
                      color: colors.textMuted,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
            ],
          ),
        ),
        SkillCollection(
          controller: widget.controller,
          selectedCategory: _categoryFilter,
        ),
      ],
    );
  }

  void _refresh() =>
      widget.controller.refreshSkillHub(_agentController.text.trim());

  void _toggleSettingsDrawer() {
    if (_settingsEntry != null) {
      _closeSettingsDrawer();
    } else {
      _showSettingsDrawer();
    }
  }

  // The drawer floats above the page without a modal barrier, so the skill
  // list keeps its scroll position and stays scrollable while it is open.
  void _showSettingsDrawer() {
    final overlay = Overlay.maybeOf(context);
    if (overlay == null) return;
    final entry = OverlayEntry(
      builder: (context) => SkillHubSettingsDrawer(
        controller: widget.controller,
        urlController: _urlController,
        onInstall: _install,
        onClose: _closeSettingsDrawer,
      ),
    );
    _settingsEntry = entry;
    overlay.insert(entry);
    setState(() {});
  }

  void _closeSettingsDrawer({bool notify = true}) {
    final entry = _settingsEntry;
    if (entry == null) return;
    _settingsEntry = null;
    entry.remove();
    if (notify && mounted) setState(() {});
  }

  Future<void> _install() async {
    final agent = _agentController.text.trim();
    final url = _urlController.text.trim();
    if (agent.isEmpty || url.isEmpty) return;
    await widget.controller.installSkillFromGitHub(
      agent: agent,
      url: url,
      pin: true,
    );
  }
}
