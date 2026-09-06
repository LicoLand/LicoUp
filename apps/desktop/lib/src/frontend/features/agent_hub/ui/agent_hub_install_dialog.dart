import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/presentation/agent_hub/agent_hub_projection.dart';

typedef AgentHubInstallSelection = ({String channelId, String version});

/// Running/terminal state of one install operation, mirrored from Agent Hub
/// effects so the install dialog can morph into its progress state in place.
enum AgentHubInstallStatus { running, succeeded, failed }

/// Opens the install dialog: pick channel and version, tap Install, and the
/// same dialog immediately shows install progress until the operation
/// completes (auto-close) or fails (error state with a close button).
///
/// [onInstall] fires synchronously on the Install tap; [installStatus] must
/// reflect the operation's terminal state afterwards.
Future<void> showAgentHubInstallFlow(
  BuildContext context, {
  required AgentHubEntryProjection recipe,
  required void Function(AgentHubInstallSelection selection) onInstall,
  required ValueListenable<AgentHubInstallStatus> installStatus,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _AgentHubInstallDialog(
      recipe: recipe,
      onInstall: onInstall,
      installStatus: installStatus,
    ),
  );
}

final class _AgentHubInstallDialog extends StatefulWidget {
  const _AgentHubInstallDialog({
    required this.recipe,
    required this.onInstall,
    required this.installStatus,
  });

  final AgentHubEntryProjection recipe;
  final void Function(AgentHubInstallSelection selection) onInstall;
  final ValueListenable<AgentHubInstallStatus> installStatus;

  @override
  State<_AgentHubInstallDialog> createState() => _AgentHubInstallDialogState();
}

final class _AgentHubInstallDialogState extends State<_AgentHubInstallDialog> {
  late String _channelId;
  late String _version;
  bool _installing = false;

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

  void _startInstall() {
    if (_channelId.isEmpty) return;
    setState(() => _installing = true);
    widget.onInstall((channelId: _channelId, version: _version));
  }

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    return ValueListenableBuilder<AgentHubInstallStatus>(
      valueListenable: widget.installStatus,
      builder: (context, status, _) {
        if (_installing && status == AgentHubInstallStatus.succeeded) {
          // Done: the hub card records the phase trail; close on this frame's
          // tail so the dialog never rebuilds after being popped.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (context.mounted) Navigator.of(context).pop();
          });
        }
        final failed = _installing && status == AgentHubInstallStatus.failed;
        return AlertDialog(
          key: const Key('agent-hub-install-dialog'),
          title: Text(
            _installing
                ? strings.agentHubInstallProgressTitle(
                    widget.recipe.displayName,
                  )
                : strings.agentHubInstallTitle,
          ),
          content: SizedBox(
            width: 360,
            child: _installing
                ? _buildProgressContent(context, strings, failed: failed)
                : _buildPickerContent(strings),
          ),
          actions: [
            if (!_installing)
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: Text(strings.cancel),
              ),
            if (failed)
              FilledButton(
                key: const Key('agent-hub-install-progress-close'),
                onPressed: () => Navigator.of(context).pop(),
                child: Text(strings.close),
              )
            else if (!_installing)
              FilledButton(
                key: const Key('agent-hub-install-start'),
                onPressed: _channelId.isEmpty ? null : _startInstall,
                child: Text(strings.install),
              ),
          ],
        );
      },
    );
  }

  Widget _buildPickerContent(LicoStrings strings) {
    final channels = widget.recipe.pickerChannels;
    return Column(
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
    );
  }

  Widget _buildProgressContent(
    BuildContext context,
    LicoStrings strings, {
    required bool failed,
  }) {
    if (failed) {
      final colors = Theme.of(context).colorScheme;
      return Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Icon(Icons.error_outline_rounded, size: 18, color: colors.error),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              strings.agentHubInstallFailedHint,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
        ],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const LinearProgressIndicator(key: Key('agent-hub-install-progress')),
        const SizedBox(height: 14),
        Text(
          strings.agentHubInstallProgressHint,
          style: Theme.of(context).textTheme.bodySmall,
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
