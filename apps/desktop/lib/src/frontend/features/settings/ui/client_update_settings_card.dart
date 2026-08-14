import 'dart:async';

import 'package:flutter/material.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/contracts/client_update_models.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

class ClientUpdateSettingsCard extends StatelessWidget {
  const ClientUpdateSettingsCard({super.key, required this.controller});

  final ClientController controller;

  void _checkFromGithub() {
    unawaited(controller.checkClientUpdateFromGithub());
  }

  void _downloadFromGithub() {
    unawaited(controller.downloadClientUpdateFromGithub());
  }

  void _applyAndRestart() {
    unawaited(
      controller.applyClientUpdateThenExit(() {
        // The detached native update script replaces the installation and
        // relaunches the new version after this process exits.
        controller.clientProcessLifecycle.exitSuccess();
      }),
    );
  }

  void _rollback() {
    unawaited(controller.rollbackClientUpdate());
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final status = controller.clientUpdateStatus;
    final busy = controller.isClientUpdateBusy;

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
            value: controller.clientUpdateSource == 'github'
                ? strings.updateSourceGithub
                : strings.updateSourceLocal,
          ),
          _InfoLine(
            label: strings.status,
            value: _phaseLabel(strings, status.phase),
          ),
          if (status.availableVersion.isNotEmpty)
            _InfoLine(
              label: strings.availableVersion,
              value: status.availableVersion,
            ),
          if (status.artifactSha256.isNotEmpty)
            _InfoLine(label: strings.digest, value: status.artifactSha256),
          _InfoLine(
            label: strings.productionReady,
            value: status.productionReady ? strings.yes : strings.no,
          ),
          const SizedBox(height: LicoContentSpacing.item),
          Wrap(
            spacing: LicoContentSpacing.compact,
            runSpacing: LicoContentSpacing.compact,
            children: [
              FilledButton.tonal(
                key: const Key('client-update-refresh-status'),
                onPressed: busy
                    ? null
                    : () => unawaited(controller.refreshClientUpdateStatus()),
                child: Text(strings.refresh),
              ),
              FilledButton(
                key: const Key('client-update-check-github'),
                onPressed: busy ? null : _checkFromGithub,
                child: Text(strings.checkUpdate),
              ),
              OutlinedButton(
                key: const Key('client-update-download-github'),
                onPressed: busy || !status.updateAvailable
                    ? null
                    : _downloadFromGithub,
                child: Text(strings.downloadUpdate),
              ),
              OutlinedButton(
                key: const Key('client-update-verify'),
                onPressed:
                    busy ||
                        (status.phase != ClientUpdatePhase.downloaded &&
                            status.phase != ClientUpdatePhase.verified &&
                            status.phase != ClientUpdatePhase.applyPlanned)
                    ? null
                    : () => unawaited(controller.verifyClientUpdateArtifact()),
                child: Text(strings.verifyUpdate),
              ),
              OutlinedButton(
                key: const Key('client-update-apply-plan'),
                onPressed: busy || status.phase != ClientUpdatePhase.verified
                    ? null
                    : () => unawaited(controller.planClientUpdateApply()),
                child: Text(strings.planUpdateInstall),
              ),
              FilledButton(
                key: const Key('client-update-apply-restart'),
                onPressed:
                    busy ||
                        (status.phase != ClientUpdatePhase.verified &&
                            status.phase != ClientUpdatePhase.applied)
                    ? null
                    : _applyAndRestart,
                child: Text(strings.applyUpdateRestart),
              ),
              OutlinedButton(
                key: const Key('client-update-rollback'),
                onPressed: busy || status.phase != ClientUpdatePhase.rolledBack
                    ? null
                    : _rollback,
                child: Text(strings.rollbackUpdate),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _phaseLabel(LicoStrings strings, ClientUpdatePhase phase) {
    return switch (phase) {
      ClientUpdatePhase.idle => strings.clientUpdatePhaseIdle,
      ClientUpdatePhase.checking => strings.clientUpdatePhaseChecking,
      ClientUpdatePhase.upToDate => strings.clientUpdatePhaseUpToDate,
      ClientUpdatePhase.updateAvailable =>
        strings.clientUpdatePhaseUpdateAvailable,
      ClientUpdatePhase.downloading => strings.clientUpdatePhaseDownloading,
      ClientUpdatePhase.downloaded => strings.clientUpdatePhaseDownloaded,
      ClientUpdatePhase.verifying => strings.clientUpdatePhaseVerifying,
      ClientUpdatePhase.verified => strings.clientUpdatePhaseVerified,
      ClientUpdatePhase.applyPlanned => strings.clientUpdatePhaseApplyPlanned,
      ClientUpdatePhase.applied => strings.clientUpdatePhaseApplied,
      ClientUpdatePhase.rolledBack => strings.clientUpdatePhaseRolledBack,
      ClientUpdatePhase.failed => strings.clientUpdatePhaseFailed,
    };
  }
}

class _InfoLine extends StatelessWidget {
  const _InfoLine({required this.label, required this.value});

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
