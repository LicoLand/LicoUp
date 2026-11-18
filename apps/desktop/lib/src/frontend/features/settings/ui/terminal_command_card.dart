import 'package:flutter/material.dart';

import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_flutter/presentation_flutter.dart';

import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/settings/settings_binding.dart';
import 'package:licoup/src/presentation/settings/settings_intent.dart';
import 'package:licoup/src/presentation/settings/settings_projection.dart';
import 'package:licoup/src/presentation/settings/settings_providers.dart';

/// The macOS "install terminal command" row inside the Startup card: one
/// dense list row like its neighbouring rows, linking
/// `terminalCommandLinkPath` to this app's bundled binary. Absent elsewhere.
final class TerminalCommandCard extends StatefulWidget {
  const TerminalCommandCard({super.key, required this.binding});

  final SettingsBinding binding;

  @override
  State<TerminalCommandCard> createState() => _TerminalCommandCardState();
}

final class _TerminalCommandCardState extends State<TerminalCommandCard> {
  @override
  void initState() {
    super.initState();
    widget.binding.intents.send(const RefreshTerminalCommand());
  }

  @override
  Widget build(BuildContext context) {
    return AsyncRegion<
      SettingsTerminalCommandProjection,
      IntentSink<SettingsIntent>
    >(
      source: settingsTerminalCommandInputsProvider,
      actions: widget.binding.intents,
      loading: (_, _) => const SizedBox.shrink(),
      data: (context, projection, actions) =>
          _buildProjection(context, projection, actions),
    );
  }

  Widget _buildProjection(
    BuildContext context,
    SettingsTerminalCommandProjection projection,
    IntentSink<SettingsIntent> actions,
  ) {
    if (!projection.supported) return const SizedBox.shrink();
    final strings = LicoStrings.of(context);
    final colors = context.licoColors;
    final busy = projection.phase == TerminalCommandPhase.applying;
    final installed = projection.status == TerminalCommandLinkStatus.installed;
    final stale = projection.status == TerminalCommandLinkStatus.stale;
    final occupied = projection.status == TerminalCommandLinkStatus.occupied;

    final (statusText, shownPath) = switch (projection.status) {
      TerminalCommandLinkStatus.installed => (
        strings.terminalCommandStatusInstalled,
        terminalCommandLinkPath,
      ),
      TerminalCommandLinkStatus.stale => (
        strings.terminalCommandStatusStale,
        terminalCommandLinkPath,
      ),
      TerminalCommandLinkStatus.occupied => (
        strings.terminalCommandStatusOccupied,
        projection.occupiedPath ?? terminalCommandLinkPath,
      ),
      TerminalCommandLinkStatus.notInstalled => (
        strings.terminalCommandStatusNotInstalled,
        terminalCommandLinkPath,
      ),
    };
    final resultText = switch (projection.result) {
      TerminalCommandResult.installed => strings.terminalCommandDone,
      TerminalCommandResult.uninstalled => strings.terminalCommandRemoved,
      TerminalCommandResult.occupied => strings.terminalCommandOccupied(
        projection.occupiedPath ?? '',
      ),
      TerminalCommandResult.cancelled => strings.terminalCommandCancelled,
      TerminalCommandResult.failed => strings.terminalCommandFailed,
      TerminalCommandResult.none => null,
      TerminalCommandResult.notInstalled => null,
    };

    return Column(
      key: const Key('terminal-command-card'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (resultText != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              resultText,
              style: TextStyle(
                color: projection.result == TerminalCommandResult.failed
                    ? colors.error
                    : colors.textMuted,
                fontSize: 12,
              ),
            ),
          ),
        ListTile(
          key: const Key('terminal-command-row'),
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: const Text('licoup'),
          subtitle: Text(
            '$statusText · $shownPath',
            key: const Key('terminal-command-status'),
            style: TextStyle(
              color: occupied ? colors.error : colors.textMuted,
              fontSize: 11,
            ),
          ),
          trailing: occupied
              ? null
              : installed
              ? OutlinedButton(
                  key: const Key('terminal-command-uninstall'),
                  onPressed: busy
                      ? null
                      : () => actions.send(const UninstallTerminalCommand()),
                  child: Text(strings.terminalCommandUninstall),
                )
              : FilledButton(
                  key: const Key('terminal-command-install'),
                  onPressed: busy
                      ? null
                      : () => actions.send(const InstallTerminalCommand()),
                  child: Text(
                    stale
                        ? strings.terminalCommandRepoint
                        : strings.terminalCommandInstall,
                  ),
                ),
        ),
      ],
    );
  }
}
