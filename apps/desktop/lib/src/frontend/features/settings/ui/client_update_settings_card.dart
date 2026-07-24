import 'dart:async';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/contracts/client_update_models.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

class ClientUpdateSettingsCard extends StatelessWidget {
  const ClientUpdateSettingsCard({super.key, required this.controller});

  final ClientController controller;

  Future<void> _pickManifestAndCheck() async {
    final manifest = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(label: 'JSON', extensions: ['json']),
      ],
    );
    if (manifest == null) {
      return;
    }
    final keys = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(label: 'JSON', extensions: ['json']),
      ],
    );
    if (keys == null) {
      return;
    }
    await controller.checkClientUpdate(
      manifestPath: manifest.path,
      publicKeysPath: keys.path,
    );
  }

  Future<void> _pickArtifactAndDownload() async {
    final artifact = await openFile();
    if (artifact == null) {
      return;
    }
    await controller.downloadClientUpdateArtifact(sourcePath: artifact.path);
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final status = controller.clientUpdateStatus;
    final busy = controller.isClientUpdateBusy;

    return Padding(
      key: const Key('client-update-settings-card'),
      padding: const EdgeInsets.fromLTRB(16, 6, 16, 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.system_update_alt, color: colors.primary, size: 18),
              const SizedBox(width: 10),
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
                    const SizedBox(height: 2),
                    Text(
                      strings.clientUpdateHint,
                      style: TextStyle(fontSize: 11, color: colors.textMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          _InfoLine(
            label: strings.version,
            value: status.currentVersion.isEmpty
                ? strings.notSelected
                : status.currentVersion,
          ),
          _InfoLine(label: strings.channel, value: status.channel),
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
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton.tonal(
                key: const Key('client-update-refresh-status'),
                onPressed: busy
                    ? null
                    : () => unawaited(controller.refreshClientUpdateStatus()),
                child: Text(strings.refresh),
              ),
              FilledButton(
                key: const Key('client-update-check'),
                onPressed: busy
                    ? null
                    : () => unawaited(_pickManifestAndCheck()),
                child: Text(strings.checkUpdate),
              ),
              OutlinedButton(
                key: const Key('client-update-download'),
                onPressed: busy || !status.updateAvailable
                    ? null
                    : () => unawaited(_pickArtifactAndDownload()),
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
      padding: const EdgeInsets.only(bottom: 4),
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
