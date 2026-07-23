import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:mime/mime.dart';

import 'package:flutter_client/src/application/controller/client_controller.dart';
import 'package:flutter_client/src/contracts/generated/secure_mesh.g.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

class SecureMeshFileSyncCard extends StatelessWidget {
  const SecureMeshFileSyncCard({super.key, required this.controller});

  final ClientController controller;

  Future<void> _pickSourceFile(BuildContext context) async {
    final file = await openFile();
    if (file == null) {
      return;
    }
    final path = file.path.trim();
    if (path.isEmpty) {
      return;
    }
    final length = await file.length();
    final mime =
        lookupMimeType(path) ?? file.mimeType ?? 'application/octet-stream';
    controller.setSecureMeshFileSyncDraft(
      fileName: file.name,
      totalSize: length,
      mimeType: mime,
    );
  }

  Future<void> _pickDestination(BuildContext context) async {
    final directory = await getDirectoryPath();
    if (directory == null || directory.trim().isEmpty) {
      return;
    }
    controller.setSecureMeshFileSyncDestination(directory.trim());
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final draft = controller.secureMeshFileSyncDraft;
    final busy = controller.isMobileRelayBusy;
    final transfers = controller.secureMeshFileSyncTransfers;
    return Container(
      key: const Key('secure-mesh-file-sync-card'),
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.surfaceLow,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.line.withAlpha(90)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            strings.fileSync,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: colors.text,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            strings.fileSyncHint,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colors.textMuted),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton.tonal(
                key: const Key('secure-mesh-file-sync-pick-source'),
                onPressed: busy ? null : () => _pickSourceFile(context),
                child: Text(strings.chooseFile),
              ),
              OutlinedButton(
                key: const Key('secure-mesh-file-sync-pick-destination'),
                onPressed: busy || draft == null
                    ? null
                    : () => _pickDestination(context),
                child: Text(strings.chooseDestination),
              ),
              FilledButton(
                key: const Key('secure-mesh-file-sync-prepare'),
                onPressed:
                    busy ||
                        draft == null ||
                        draft.destinationRoot.isEmpty ||
                        draft.status ==
                            SecureMeshFileSyncStatus.awaitingConfirmation
                    ? null
                    : controller.prepareSecureMeshFileSyncTransfer,
                child: Text(strings.prepareFileSync),
              ),
            ],
          ),
          if (draft != null) ...[
            const SizedBox(height: 14),
            _InfoLine(label: strings.file, value: draft.fileName),
            _InfoLine(
              label: strings.fileSyncSize,
              value: '${draft.totalSize} B / ${draft.chunkCount} chunks',
            ),
            _InfoLine(
              label: strings.destination,
              value: draft.destinationRoot.isEmpty
                  ? strings.notSelected
                  : draft.destinationRoot,
            ),
            _InfoLine(
              label: strings.status,
              value: _statusLabel(strings, draft.status),
            ),
          ],
          if (draft?.awaitsConfirmation == true) ...[
            const SizedBox(height: 12),
            Text(
              strings.fileSyncConfirmationPrompt,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: colors.text),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                FilledButton(
                  key: const Key('secure-mesh-file-sync-confirm'),
                  onPressed: busy
                      ? null
                      : () => controller.confirmSecureMeshFileSyncReceive(
                          userConfirmed: true,
                        ),
                  child: Text(strings.confirmWrite),
                ),
                OutlinedButton(
                  key: const Key('secure-mesh-file-sync-reject'),
                  onPressed: busy
                      ? null
                      : () => controller.confirmSecureMeshFileSyncReceive(
                          userConfirmed: false,
                        ),
                  child: Text(strings.rejectWrite),
                ),
              ],
            ),
          ],
          if (transfers.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              strings.fileSyncQueue,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: colors.text,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            for (final transfer in transfers.reversed.take(6))
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  '${transfer.fileName} · ${_statusLabel(strings, transfer.status)}',
                  key: Key('secure-mesh-file-sync-queue-${transfer.id}'),
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(color: colors.textMuted),
                ),
              ),
          ],
        ],
      ),
    );
  }

  String _statusLabel(LicoStrings strings, SecureMeshFileSyncStatus status) {
    return switch (status) {
      SecureMeshFileSyncStatus.drafting => strings.fileSyncStatusDrafting,
      SecureMeshFileSyncStatus.evaluating => strings.fileSyncStatusEvaluating,
      SecureMeshFileSyncStatus.awaitingConfirmation =>
        strings.fileSyncStatusAwaitingConfirmation,
      SecureMeshFileSyncStatus.confirmed => strings.fileSyncStatusConfirmed,
      SecureMeshFileSyncStatus.rejected => strings.fileSyncStatusRejected,
      SecureMeshFileSyncStatus.failed => strings.fileSyncStatusFailed,
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
            width: 110,
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
