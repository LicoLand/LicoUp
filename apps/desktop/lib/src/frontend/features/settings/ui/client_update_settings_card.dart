import 'dart:async';

import 'package:flutter/material.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/contracts/client_update_models.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

class ClientUpdateSettingsCard extends StatefulWidget {
  const ClientUpdateSettingsCard({super.key, required this.controller});

  final ClientController controller;

  @override
  State<ClientUpdateSettingsCard> createState() =>
      _ClientUpdateSettingsCardState();
}

class _ClientUpdateSettingsCardState extends State<ClientUpdateSettingsCard> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        unawaited(widget.controller.hydrateClientUpdateIdentity());
      }
    });
  }

  void _checkFromGithub() {
    unawaited(widget.controller.checkClientUpdateFromGithub());
  }

  void _downloadFromGithub() {
    unawaited(widget.controller.downloadClientUpdateFromGithub());
  }

  void _applyAndRestart() {
    unawaited(
      widget.controller.applyClientUpdateThenExit(() {
        // The detached native update script replaces the installation and
        // relaunches the new version after this process exits.
        widget.controller.clientProcessLifecycle.exitSuccess();
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final controller = widget.controller;
    final status = controller.clientUpdateStatus;
    final busy = controller.isClientUpdateBusy;
    final canCheck = !busy;
    final canDownload =
        !busy &&
        status.updateAvailable &&
        status.phase == ClientUpdatePhase.updateAvailable;
    final canApply =
        !busy &&
        (status.phase == ClientUpdatePhase.verified ||
            status.phase == ClientUpdatePhase.applyPlanned);
    final sourceAddress = clientUpdatePublicSourceAddress(
      repo: controller.clientUpdateRepo,
      githubReleaseUrl: status.githubReleaseUrl,
    );

    final presentation = LayoutDestinationPresentationScope.settingsOf(context);
    return Padding(
      key: const Key('client-update-settings-card'),
      padding: presentation.rowPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(
                Icons.system_update_alt,
                color: colors.textSecondary,
                size: 18,
              ),
              const SizedBox(width: LicoContentSpacing.compact),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      strings.clientUpdate,
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: colors.text,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: LicoContentSpacing.inline / 2),
                    Text(
                      strings.clientUpdateHint,
                      style: TextStyle(fontSize: 11, color: colors.textMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: LicoContentSpacing.item),
          _InfoLine(
            label: strings.version,
            value: status.currentVersion.isEmpty
                ? strings.notSelected
                : status.currentVersion,
          ),
          _InfoLine(label: strings.channel, value: status.channel),
          _InfoLine(
            label: strings.updateSource,
            value: strings.updateSourceGithub,
          ),
          _InfoLine(
            key: const Key('client-update-source-address'),
            label: strings.sourceAddress,
            value: sourceAddress,
          ),
          if (status.availableVersion.isNotEmpty)
            _InfoLine(
              label: strings.availableVersion,
              value: status.availableVersion,
            ),
          if (status.artifactSha256.isNotEmpty)
            _InfoLine(label: strings.digest, value: status.artifactSha256),
          const SizedBox(height: LicoContentSpacing.item),
          Wrap(
            spacing: LicoContentSpacing.compact,
            runSpacing: LicoContentSpacing.compact,
            children: [
              FilledButton(
                key: const Key('client-update-check-github'),
                onPressed: canCheck ? _checkFromGithub : null,
                child: Text(strings.checkUpdate),
              ),
              OutlinedButton(
                key: const Key('client-update-download-local'),
                onPressed: canDownload ? _downloadFromGithub : null,
                child: Text(strings.downloadToLocal),
              ),
              FilledButton(
                key: const Key('client-update-apply-restart'),
                onPressed: canApply ? _applyAndRestart : null,
                child: Text(strings.updateAndRestart),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _InfoLine extends StatelessWidget {
  const _InfoLine({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Padding(
      padding: const EdgeInsets.only(bottom: LicoContentSpacing.inline),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 120,
            child: Text(
              label,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.textMuted),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.text),
            ),
          ),
        ],
      ),
    );
  }
}
