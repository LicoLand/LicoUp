import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/presentation/agent_hub/agent_hub_projection.dart';

typedef AgentHubInstallSelection = ({String channelId, String version});

Future<AgentHubInstallSelection?> showAgentHubInstallFlow(
  BuildContext context, {
  required AgentHubEntryProjection recipe,
}) async {
  final picked = await showDialog<AgentHubInstallSelection>(
    context: context,
    builder: (context) => _AgentHubInstallPickerDialog(recipe: recipe),
  );
  if (picked == null || !context.mounted) {
    return null;
  }
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) =>
        _AgentHubInstallConfirmDialog(displayName: recipe.displayName),
  );
  if (confirmed != true) {
    return null;
  }
  return picked;
}

final class _AgentHubInstallPickerDialog extends StatefulWidget {
  const _AgentHubInstallPickerDialog({required this.recipe});

  final AgentHubEntryProjection recipe;

  @override
  State<_AgentHubInstallPickerDialog> createState() =>
      _AgentHubInstallPickerDialogState();
}

final class _AgentHubInstallPickerDialogState
    extends State<_AgentHubInstallPickerDialog> {
  late String _channelId;
  late String _version;

  @override
  void initState() {
    super.initState();
    final channels = widget.recipe.pickerChannels;
    _channelId = channels.isEmpty ? '' : channels.first.id;
    _version = 'latest';
  }

  AgentHubChannelProjection? get _selectedChannel {
    final channels = widget.recipe.pickerChannels;
    for (final channel in channels) {
      if (channel.id == _channelId) {
        return channel;
      }
    }
    return channels.isEmpty ? null : channels.first;
  }

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final channels = widget.recipe.pickerChannels;
    return AlertDialog(
      key: const Key('agent-hub-install-dialog'),
      title: Text(strings.agentHubInstallTitle),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<String>(
              key: const Key('agent-hub-install-channel'),
              initialValue: channels.any((channel) => channel.id == _channelId)
                  ? _channelId
                  : null,
              decoration: InputDecoration(
                labelText: strings.agentHubPackageManager,
              ),
              items: [
                for (final channel in channels)
                  DropdownMenuItem(
                    value: channel.id,
                    child: Text(channel.chipLabel),
                  ),
              ],
              onChanged: (value) {
                if (value == null) {
                  return;
                }
                setState(() => _channelId = value);
              },
            ),
            const SizedBox(height: 14),
            DropdownButtonFormField<String>(
              key: const Key('agent-hub-install-version'),
              initialValue: _version,
              decoration: InputDecoration(labelText: strings.agentHubVersion),
              items: [
                DropdownMenuItem(
                  value: 'latest',
                  child: Text(strings.agentHubLatest),
                ),
              ],
              onChanged: (value) {
                if (value == null) {
                  return;
                }
                setState(() => _version = value);
              },
            ),
            const SizedBox(height: 14),
            _InstallPreviewField(
              fieldKey: const Key('agent-hub-install-source'),
              label: strings.agentHubDownloadSource,
              value: _selectedChannel?.httpsSource?.toString() ?? '',
            ),
            const SizedBox(height: 14),
            _InstallPreviewField(
              fieldKey: const Key('agent-hub-install-command'),
              label: strings.agentHubPendingCommand,
              value: _selectedChannel?.commandPreview ?? '',
              monospace: true,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(strings.cancel),
        ),
        FilledButton(
          key: const Key('agent-hub-install-continue'),
          onPressed: _channelId.isEmpty
              ? null
              : () => Navigator.of(
                  context,
                ).pop((channelId: _channelId, version: _version)),
          child: Text(strings.agentHubInstallContinue),
        ),
      ],
    );
  }
}

final class _InstallPreviewField extends StatelessWidget {
  const _InstallPreviewField({
    required this.fieldKey,
    required this.label,
    required this.value,
    this.monospace = false,
  });

  final Key fieldKey;
  final String label;
  final String value;
  final bool monospace;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InputDecorator(
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
      child: SelectableText(
        value.isEmpty ? '—' : value,
        key: fieldKey,
        style:
            (monospace ? theme.textTheme.bodySmall : theme.textTheme.bodyMedium)
                ?.copyWith(
                  fontFamily: monospace ? 'monospace' : null,
                  height: 1.35,
                ),
      ),
    );
  }
}

final class _AgentHubInstallConfirmDialog extends StatelessWidget {
  const _AgentHubInstallConfirmDialog({required this.displayName});

  final String displayName;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    return AlertDialog(
      key: const Key('agent-hub-install-confirm-dialog'),
      title: Text(strings.agentHubInstallConfirmTitle(displayName)),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: Text(strings.cancel),
        ),
        FilledButton(
          key: const Key('agent-hub-install-confirm'),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(strings.agentHubInstallConfirmAction),
        ),
      ],
    );
  }
}
