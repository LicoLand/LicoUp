import 'package:flutter/material.dart';

import 'package:flutter_client/src/application/controller/client_controller.dart';
import 'package:flutter_client/src/frontend/features/skill_hub/ui/skill_management_section.dart';
import 'package:flutter_client/src/frontend/features/skill_hub/ui/skill_hub_panel_catalog.dart';
import 'package:flutter_client/src/frontend/features/skill_hub/ui/skill_hub_panel_widgets.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';

export 'package:flutter_client/src/frontend/features/skill_hub/ui/skill_hub_panel_icon_picker.dart'
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
  final TextEditingController _targetController = TextEditingController(
    text: 'manual',
  );
  final TextEditingController _urlController = TextEditingController();
  final TextEditingController _installRootController = TextEditingController();
  final TextEditingController _skillNameController = TextEditingController();
  final TextEditingController _rollbackSnapshotController =
      TextEditingController();
  bool _overwrite = false;
  bool _pin = true;

  bool _showDeveloperTools = false;
  String _categoryFilter = 'all';

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
    _agentController.dispose();
    _targetController.dispose();
    _urlController.dispose();
    _installRootController.dispose();
    _skillNameController.dispose();
    _rollbackSnapshotController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final strings = LicoStrings.of(context);
    final agentOptions = {
      _agentController.text.trim(),
      ...controller.scannedTargets.map((target) => target.target),
    }.where((agent) => agent.isNotEmpty).toList();

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: ListTile(
            leading: const Icon(Icons.library_books_outlined),
            title: Text(strings.skillHub),
            subtitle: Text(strings.skillHubSubtitle),
            trailing: IconButton(
              tooltip: _showDeveloperTools
                  ? strings.hideSkillHubSettings
                  : strings.showSkillHubSettings,
              onPressed: () {
                setState(() => _showDeveloperTools = !_showDeveloperTools);
              },
              icon: Icon(
                _showDeveloperTools ? Icons.settings : Icons.settings_outlined,
              ),
            ),
          ),
        ),
        const SliverToBoxAdapter(child: Divider(height: 1)),
        if (_showDeveloperTools) ...[
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Wrap(
                spacing: 12,
                runSpacing: 12,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  agentOptions.length > 1
                      ? SkillAgentDropdown(
                          value: _agentController.text.trim(),
                          options: agentOptions,
                          onChanged: (value) {
                            if (value == null) return;
                            setState(() => _agentController.text = value);
                          },
                        )
                      : SkillPanelTextField(
                          controller: _agentController,
                          label: strings.agent,
                          width: 180,
                        ),
                  SkillPanelTextField(
                    controller: _targetController,
                    label: strings.target,
                    width: 180,
                  ),
                  OutlinedButton.icon(
                    onPressed: controller.isSkillHubBusy ? null : _request,
                    icon: const Icon(Icons.link_outlined, size: 18),
                    label: Text(strings.request),
                  ),
                  FilledButton.icon(
                    onPressed: controller.isSkillHubBusy ? null : _approve,
                    icon: const Icon(Icons.verified_user_outlined, size: 18),
                    label: Text(strings.approve),
                  ),
                  OutlinedButton.icon(
                    onPressed: controller.isSkillHubBusy ? null : _revoke,
                    icon: const Icon(Icons.link_off_outlined, size: 18),
                    label: Text(strings.revoke),
                  ),
                ],
              ),
            ),
          ),
          const SliverToBoxAdapter(child: Divider(height: 1)),
          SliverToBoxAdapter(
            child: SkillInstallerSection(
              controller: controller,
              urlController: _urlController,
              skillNameController: _skillNameController,
              installRootController: _installRootController,
              rollbackSnapshotController: _rollbackSnapshotController,
              overwrite: _overwrite,
              pin: _pin,
              onOverwriteChanged: (value) {
                setState(() => _overwrite = value);
              },
              onPinChanged: (value) {
                setState(() => _pin = value);
              },
              onPreviewInstall: _previewInstall,
              onInstall: _install,
              onRollbackInstall: _rollbackInstall,
            ),
          ),
          const SliverToBoxAdapter(child: Divider(height: 1)),
          SliverToBoxAdapter(
            child: SkillManagementSection(
              updateController: controller,
              deleteController: controller,
              usageController: controller,
              agentController: _agentController,
              installRootController: _installRootController,
              agentOptions: agentOptions,
            ),
          ),
          const SliverToBoxAdapter(child: Divider(height: 1)),
          SliverToBoxAdapter(
            child: SkillSectionHeader(
              title: strings.isChinese ? '配对记录' : 'Pairings',
              count: controller.skillHubPairings.length,
            ),
          ),
          SliverList(
            delegate: SliverChildBuilderDelegate((context, index) {
              final pairing = controller.skillHubPairings[index];
              return ListTile(
                dense: true,
                title: Text((pairing['agentId'] ?? '').toString()),
                subtitle: Text(
                  skillPairingTargetLabel(
                    strings,
                    (pairing['target'] ?? '').toString(),
                  ),
                ),
                trailing: Text(
                  skillPairingStatusLabel(
                    strings,
                    (pairing['status'] ?? '').toString(),
                  ),
                ),
              );
            }, childCount: controller.skillHubPairings.length),
          ),
          const SliverToBoxAdapter(child: Divider(height: 1)),
        ],
        SliverToBoxAdapter(
          child: SkillCategoryFilter(
            selectedCategory: _categoryFilter,
            onChanged: (category) {
              setState(() => _categoryFilter = category);
            },
          ),
        ),
        SkillCollection(
          controller: controller,
          selectedCategory: _categoryFilter,
        ),
      ],
    );
  }

  String get _agent => _agentController.text.trim();
  String get _target => _targetController.text.trim();
  String get _url => _urlController.text.trim();
  String get _installRoot => _installRootController.text.trim();
  String get _skillName => _skillNameController.text.trim();
  String get _rollbackSnapshot => _rollbackSnapshotController.text.trim();

  void _refresh() => widget.controller.refreshSkillHub(_agent);
  void _request() =>
      widget.controller.requestSkillHubPairing(_agent, target: _target);
  void _approve() => widget.controller.approveSkillHubPairing(_agent);
  void _revoke() => widget.controller.revokeSkillHubPairing(_agent);

  Future<void> _previewInstall() async {
    if (_agent.isEmpty || _url.isEmpty) return;
    await widget.controller.previewSkillInstall(
      agent: _agent,
      url: _url,
      installRoot: _installRoot,
      name: _skillName,
      overwrite: _overwrite,
    );
  }

  Future<void> _install() async {
    if (_agent.isEmpty || _url.isEmpty) return;
    await widget.controller.installSkillFromGitHub(
      agent: _agent,
      url: _url,
      installRoot: _installRoot,
      name: _skillName,
      overwrite: _overwrite,
      pin: _pin,
    );
    final snapshotId =
        widget.controller.skillInstallResult?['rollbackSnapshotId']
            ?.toString() ??
        '';
    if (mounted && snapshotId.isNotEmpty) {
      setState(() => _rollbackSnapshotController.text = snapshotId);
    }
  }

  Future<void> _rollbackInstall() async {
    if (_agent.isEmpty || _rollbackSnapshot.isEmpty) return;
    await widget.controller.rollbackSkillInstall(
      agent: _agent,
      snapshotId: _rollbackSnapshot,
    );
  }
}
