import 'package:flutter/material.dart';

import 'package:flutter_client/src/application/features/settings/controller/optional_collaboration_controller.dart';
import 'package:flutter_client/src/contracts/optional_collaboration_models.dart';
import 'package:flutter_client/src/frontend/features/settings/ui/optional_collaboration_settings_action_card.dart';

final class OptionalCollaborationEnableSection extends StatefulWidget {
  const OptionalCollaborationEnableSection({
    super.key,
    required this.controller,
    required this.busy,
    required this.isChinese,
  });

  final OptionalCollaborationController controller;
  final bool busy;
  final bool isChinese;

  @override
  State<OptionalCollaborationEnableSection> createState() =>
      _OptionalCollaborationEnableSectionState();
}

final class _OptionalCollaborationEnableSectionState
    extends State<OptionalCollaborationEnableSection> {
  bool _confirmed = false;

  @override
  Widget build(BuildContext context) {
    return OptionalCollaborationSettingsActionCard(
      key: const Key('collaboration-enable-action'),
      title: widget.isChinese ? '启用可选协作' : 'Enable optional collaboration',
      confirmation: widget.isChinese
          ? '我确认仅启用能力；此操作不会安装或加载插件。'
          : 'I confirm this only enables the capability; it does not install or load a plugin.',
      buttonLabel: widget.isChinese ? '启用' : 'Enable',
      value: _confirmed,
      busy: widget.busy,
      onChanged: (value) => setState(() => _confirmed = value ?? false),
      onPressed: _confirmed ? _enable : null,
    );
  }

  Future<void> _enable() async {
    final applied = await widget.controller.enable(confirmed: true);
    if (mounted && applied) setState(() => _confirmed = false);
  }
}

final class OptionalCollaborationTeardownSection extends StatefulWidget {
  const OptionalCollaborationTeardownSection({
    super.key,
    required this.controller,
    required this.state,
    required this.busy,
    required this.isChinese,
  });

  final OptionalCollaborationController controller;
  final OptionalCollaborationRuntimeState state;
  final bool busy;
  final bool isChinese;

  @override
  State<OptionalCollaborationTeardownSection> createState() =>
      _OptionalCollaborationTeardownSectionState();
}

final class _OptionalCollaborationTeardownSectionState
    extends State<OptionalCollaborationTeardownSection> {
  bool _uninstallConfirmed = false;
  bool _disableConfirmed = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (widget.state.pluginInstalled) ...[
          OptionalCollaborationSettingsActionCard(
            key: const Key('collaboration-uninstall-action'),
            title: widget.isChinese ? '卸载插件' : 'Uninstall plugin',
            detail:
                '${widget.isChinese ? '已安装摘要' : 'Installed digest'}: ${widget.state.plugin?.packageDigestSha256 ?? ''}',
            confirmation: widget.isChinese
                ? '我确认卸载上方精确摘要对应的插件，并停用可选协作。'
                : 'I confirm uninstalling the plugin bound to the exact digest above and disabling optional collaboration.',
            buttonLabel: widget.isChinese ? '卸载' : 'Uninstall',
            value: _uninstallConfirmed,
            busy: widget.busy,
            destructive: true,
            onChanged: (value) =>
                setState(() => _uninstallConfirmed = value ?? false),
            onPressed: _uninstallConfirmed ? _uninstall : null,
          ),
          const SizedBox(height: 12),
        ],
        if (widget.state.capabilityEnabled)
          OptionalCollaborationSettingsActionCard(
            key: const Key('collaboration-disable-action'),
            title: widget.isChinese
                ? '停用可选协作'
                : 'Disable optional collaboration',
            confirmation: widget.isChinese
                ? '我确认停用该能力；已安装插件不会在后台加载。'
                : 'I confirm disabling the capability; an installed plugin will not load in the background.',
            buttonLabel: widget.isChinese ? '停用' : 'Disable',
            value: _disableConfirmed,
            busy: widget.busy,
            onChanged: (value) =>
                setState(() => _disableConfirmed = value ?? false),
            onPressed: _disableConfirmed ? _disable : null,
          ),
      ],
    );
  }

  Future<void> _uninstall() async {
    final applied = await widget.controller.uninstall(confirmed: true);
    if (mounted && applied) setState(() => _uninstallConfirmed = false);
  }

  Future<void> _disable() async {
    final applied = await widget.controller.disable(confirmed: true);
    if (mounted && applied) setState(() => _disableConfirmed = false);
  }
}
