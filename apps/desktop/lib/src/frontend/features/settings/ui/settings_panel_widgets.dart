part of 'package:flutter_client/src/frontend/features/settings/ui/settings_panel.dart';

class _SettingsDropdownRow<T> extends StatelessWidget {
  const _SettingsDropdownRow({
    required this.icon,
    required this.title,
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final T? value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?> onChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final presentation = LayoutDestinationPresentationScope.settingsOf(context);
    final titleStyle = Theme.of(context).textTheme.titleSmall?.copyWith(
      color: colors.text,
      fontWeight: FontWeight.w600,
    );
    return Padding(
      padding: presentation.rowPadding,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 560;
          final titleRow = Row(
            children: [
              Icon(icon, color: colors.primary, size: 18),
              const SizedBox(width: 10),
              Expanded(child: Text(title, style: titleStyle)),
            ],
          );
          final dropdown = DropdownButtonFormField<T>(
            initialValue: value,
            decoration: _dropdownDecorationWithoutLabel(),
            items: items,
            onChanged: onChanged,
          );
          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [titleRow, const SizedBox(height: 8), dropdown],
            );
          }
          return Row(
            children: [
              Expanded(child: titleRow),
              const SizedBox(width: 16),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: dropdown,
              ),
            ],
          );
        },
      ),
    );
  }
}

class _AssistantAgentSettings extends StatefulWidget {
  const _AssistantAgentSettings({required this.controller});

  final ClientController controller;

  @override
  State<_AssistantAgentSettings> createState() =>
      _AssistantAgentSettingsState();
}

class _AssistantAgentSettingsState extends State<_AssistantAgentSettings> {
  bool _selectingEnabled = false;

  ClientController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    _selectingEnabled = controller.assistantAgentEnabled;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final configuredTarget = controller.assistantAgentTargetId;
    final options = _assistantAgentOptions(
      controller.scannedTargets,
      configuredTarget,
      strings,
    );
    final selectedValue =
        options.any((option) => option.target == configuredTarget)
        ? configuredTarget
        : null;
    final enabled = _selectingEnabled || configuredTarget.isNotEmpty;
    final busy =
        controller.isSavingSnapshotCurator || controller.isScanningTargets;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Icon(
                Icons.support_agent_outlined,
                color: colors.primary,
                size: 18,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  strings.assistantAgent,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: colors.text,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              IconButton(
                tooltip: strings.scanAssistantAgents,
                onPressed: busy ? null : () => unawaited(_refreshOptions()),
                icon: controller.isScanningTargets
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.refresh_outlined, size: 18),
              ),
              Switch.adaptive(
                value: enabled,
                onChanged: controller.isSavingSnapshotCurator
                    ? null
                    : _toggleAssistantAgent,
              ),
            ],
          ),
          const SizedBox(height: 10),
          DropdownButtonFormField<String>(
            key: ValueKey(
              'assistant-agent-$enabled-$selectedValue-${options.length}',
            ),
            initialValue: selectedValue?.isEmpty == true ? null : selectedValue,
            decoration: InputDecoration(
              labelText: strings.chooseAssistantAgent,
              helperText: strings.assistantAgentDescription,
            ),
            hint: Text(
              options.isEmpty
                  ? strings.noAssistantAgentsAvailable
                  : strings.assistantAgentPendingSelection,
            ),
            items: [
              for (final option in options)
                DropdownMenuItem(
                  value: option.target,
                  child: Text(option.label),
                ),
            ],
            onChanged: enabled && !busy && options.isNotEmpty
                ? (target) {
                    if (target == null) {
                      return;
                    }
                    setState(() {
                      _selectingEnabled = true;
                    });
                    unawaited(controller.setAssistantAgent(target));
                  }
                : null,
          ),
        ],
      ),
    );
  }

  Future<void> _refreshOptions() async {
    await controller.scanTargets();
    await controller.refreshAssistantAgent();
  }

  void _toggleAssistantAgent(bool enabled) {
    setState(() {
      _selectingEnabled = enabled;
    });
    if (!enabled) {
      unawaited(controller.clearAssistantAgent());
      return;
    }
    if (controller.scannedTargets.isEmpty && !controller.isScanningTargets) {
      unawaited(controller.scanTargets());
    }
  }
}

class _AssistantAgentOption {
  const _AssistantAgentOption({required this.target, required this.label});

  final String target;
  final String label;
}

List<_AssistantAgentOption> _assistantAgentOptions(
  Iterable<TargetCandidate> targets,
  String configuredTarget,
  LicoStrings strings,
) {
  final options = targets
      .where(_isAssistantAgentCandidate)
      .map(
        (target) => _AssistantAgentOption(
          target: target.target,
          label: target.kind.trim().isEmpty
              ? target.label
              : '${target.label} · ${strings.targetKindLabel(target.kind)}',
        ),
      )
      .toList(growable: true);
  if (configuredTarget.isNotEmpty &&
      !options.any((option) => option.target == configuredTarget)) {
    options.add(
      _AssistantAgentOption(target: configuredTarget, label: configuredTarget),
    );
  }
  return List.unmodifiable(options);
}

bool _isAssistantAgentCandidate(TargetCandidate target) {
  return target.visibleInClient &&
      target.target != 'code' &&
      target.target != 'vscode';
}
