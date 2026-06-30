import 'package:flutter/material.dart';

import '../controllers/future_client_controller.dart';
import 'panel_frame.dart';

part 'skill_hub_panel_widgets.dart';

class SkillHubPanel extends StatefulWidget {
  const SkillHubPanel({super.key, required this.controller});

  final FutureClientController controller;

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
    final agentOptions = {
      _agentController.text.trim(),
      ...controller.scannedTargets.map((target) => target.target),
    }.where((agent) => agent.isNotEmpty).toList();
    return PanelFrame(
      child: ListView(
        children: [
          ListTile(
            leading: const Icon(Icons.library_books_outlined),
            title: const Text('Skill Hub'),
            subtitle: const Text(
              'Pair agents and inspect visible skills from portable state.',
            ),
            trailing: IconButton(
              tooltip: 'Refresh Skill Hub',
              onPressed: controller.isSkillHubBusy ? null : _refresh,
              icon: controller.isSkillHubBusy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
            ),
          ),
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Wrap(
              spacing: 12,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                agentOptions.length > 1
                    ? _AgentDropdown(
                        value: _agentController.text.trim(),
                        options: agentOptions,
                        onChanged: (value) {
                          if (value == null) return;
                          setState(() => _agentController.text = value);
                        },
                      )
                    : _PanelTextField(
                        controller: _agentController,
                        label: 'Agent',
                        width: 180,
                      ),
                _PanelTextField(
                  controller: _targetController,
                  label: 'Target',
                  width: 180,
                ),
                OutlinedButton.icon(
                  onPressed: controller.isSkillHubBusy ? null : _request,
                  icon: const Icon(Icons.link_outlined, size: 18),
                  label: const Text('Request'),
                ),
                FilledButton.icon(
                  onPressed: controller.isSkillHubBusy ? null : _approve,
                  icon: const Icon(Icons.verified_user_outlined, size: 18),
                  label: const Text('Approve'),
                ),
                OutlinedButton.icon(
                  onPressed: controller.isSkillHubBusy ? null : _revoke,
                  icon: const Icon(Icons.link_off_outlined, size: 18),
                  label: const Text('Revoke'),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          _SkillInstallerSection(
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
          const Divider(height: 1),
          _SectionHeader(
            title: 'Pairings',
            count: controller.skillHubPairings.length,
          ),
          for (final pairing in controller.skillHubPairings)
            ListTile(
              dense: true,
              title: Text((pairing['agentId'] ?? '').toString()),
              subtitle: Text((pairing['target'] ?? '').toString()),
              trailing: Text((pairing['status'] ?? '').toString()),
            ),
          _SectionHeader(
            title: 'Visible Skills',
            count: controller.skillHubSkills.length,
          ),
          for (final skill in controller.skillHubSkills)
            ListTile(
              dense: true,
              title: Text((skill['skillId'] ?? '').toString()),
              subtitle: Text(
                (skill['version'] ?? skill['path'] ?? '').toString(),
              ),
              trailing: Text((skill['protocolStatus'] ?? 'visible').toString()),
            ),
        ],
      ),
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
