part of 'skill_hub_panel.dart';

class _SkillInstallerSection extends StatelessWidget {
  const _SkillInstallerSection({
    required this.controller,
    required this.urlController,
    required this.skillNameController,
    required this.installRootController,
    required this.rollbackSnapshotController,
    required this.overwrite,
    required this.pin,
    required this.onOverwriteChanged,
    required this.onPinChanged,
    required this.onPreviewInstall,
    required this.onInstall,
    required this.onRollbackInstall,
  });

  final FutureClientController controller;
  final TextEditingController urlController;
  final TextEditingController skillNameController;
  final TextEditingController installRootController;
  final TextEditingController rollbackSnapshotController;
  final bool overwrite;
  final bool pin;
  final ValueChanged<bool> onOverwriteChanged;
  final ValueChanged<bool> onPinChanged;
  final Future<void> Function() onPreviewInstall;
  final Future<void> Function() onInstall;
  final Future<void> Function() onRollbackInstall;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const _SectionHeader(title: 'Install From GitHub'),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _PanelTextField(
                controller: urlController,
                label: 'GitHub URL',
                width: 420,
              ),
              _PanelTextField(
                controller: skillNameController,
                label: 'Skill ID',
                width: 180,
              ),
              _PanelTextField(
                controller: installRootController,
                label: 'Install root',
                width: 300,
              ),
              _PanelCheckbox(
                value: overwrite,
                label: 'Overwrite',
                onChanged: onOverwriteChanged,
              ),
              _PanelCheckbox(value: pin, label: 'Pin', onChanged: onPinChanged),
              OutlinedButton.icon(
                onPressed: controller.isSkillHubBusy
                    ? null
                    : () {
                        onPreviewInstall();
                      },
                icon: const Icon(Icons.visibility_outlined, size: 18),
                label: const Text('Preview'),
              ),
              FilledButton.icon(
                onPressed: controller.isSkillHubBusy
                    ? null
                    : () {
                        onInstall();
                      },
                icon: const Icon(Icons.download_outlined, size: 18),
                label: const Text('Install'),
              ),
            ],
          ),
        ),
        if (controller.skillInstallPlan != null)
          _ResultSummary(
            title: 'Install Plan',
            result: controller.skillInstallPlan!,
            keys: const [
              'status',
              'skillId',
              'title',
              'version',
              'installDir',
              'installBlockedReason',
              'packageDigestSha256',
            ],
          ),
        if (controller.skillInstallResult != null)
          _ResultSummary(
            title: 'Install Result',
            result: controller.skillInstallResult!,
            keys: const [
              'status',
              'skillId',
              'installDir',
              'rollbackSnapshotId',
              'packageDigestSha256',
            ],
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
          child: Wrap(
            spacing: 12,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _PanelTextField(
                controller: rollbackSnapshotController,
                label: 'Rollback snapshot',
                width: 300,
              ),
              OutlinedButton.icon(
                onPressed: controller.isSkillHubBusy
                    ? null
                    : () {
                        onRollbackInstall();
                      },
                icon: const Icon(Icons.undo_outlined, size: 18),
                label: const Text('Rollback'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _AgentDropdown extends StatelessWidget {
  const _AgentDropdown({
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final String value;
  final List<String> options;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context) {
    final selectedValue = options.contains(value) ? value : options.first;
    return SizedBox(
      width: 180,
      child: DropdownButtonFormField<String>(
        key: ValueKey(selectedValue),
        initialValue: selectedValue,
        decoration: const InputDecoration(
          isDense: true,
          labelText: 'Agent',
          border: OutlineInputBorder(),
        ),
        items: [
          for (final option in options)
            DropdownMenuItem(value: option, child: Text(option)),
        ],
        onChanged: onChanged,
      ),
    );
  }
}

class _PanelTextField extends StatelessWidget {
  const _PanelTextField({
    required this.controller,
    required this.label,
    required this.width,
  });

  final TextEditingController controller;
  final String label;
  final double width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: TextField(
        controller: controller,
        decoration: InputDecoration(
          isDense: true,
          labelText: label,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }
}

class _PanelCheckbox extends StatelessWidget {
  const _PanelCheckbox({
    required this.value,
    required this.label,
    required this.onChanged,
  });

  final bool value;
  final String label;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 140,
      child: CheckboxListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        value: value,
        title: Text(label),
        onChanged: (next) => onChanged(next ?? false),
      ),
    );
  }
}

class _ResultSummary extends StatelessWidget {
  const _ResultSummary({
    required this.title,
    required this.result,
    required this.keys,
  });

  final String title;
  final Map<String, dynamic> result;
  final List<String> keys;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final entries = keys
        .where(
          (key) => result[key] != null && result[key].toString().isNotEmpty,
        )
        .map((key) => MapEntry(key, result[key].toString()))
        .toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          for (final entry in entries)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: SelectableText('${entry.key}: ${entry.value}'),
            ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.count});

  final String title;
  final int? count;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      title: Text(title),
      trailing: count == null ? null : Text('$count'),
    );
  }
}
