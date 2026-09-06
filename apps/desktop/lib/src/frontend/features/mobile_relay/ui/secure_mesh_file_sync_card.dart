import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:mime/mime.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_intent.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_projection.dart';

class SecureMeshFileSyncCard extends StatelessWidget {
  const SecureMeshFileSyncCard({
    super.key,
    required this.projection,
    required this.intents,
  });

  final MobileRelayProjection projection;
  final IntentSink<MobileRelayIntent> intents;

  Future<void> _pickSourceFile() async {
    // The protected file picker remains directly user-triggered.
    final file = await openFile();
    if (file == null) return;
    final path = file.path.trim();
    if (path.isEmpty) return;
    final length = await file.length();
    final mime =
        lookupMimeType(path) ?? file.mimeType ?? 'application/octet-stream';
    intents.send(
      SetRelayTransferSource(
        fileName: file.name,
        totalSize: length,
        mimeType: mime,
      ),
    );
  }

  Future<void> _pickDestination() async {
    // The directory permission prompt is likewise deferred until this tap.
    final directory = await getDirectoryPath();
    if (directory == null || directory.trim().isEmpty) return;
    intents.send(SetRelayTransferDestination(directory.trim()));
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final draft = projection.draftTransfer;
    return Container(
      key: const Key('secure-mesh-file-sync-card'),
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: colors.surfaceLow,
        borderRadius: BorderRadius.circular(LicoRadius.card),
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
                onPressed: projection.busy ? null : _pickSourceFile,
                child: Text(strings.chooseFile),
              ),
              OutlinedButton(
                key: const Key('secure-mesh-file-sync-pick-destination'),
                onPressed: projection.busy || draft == null
                    ? null
                    : _pickDestination,
                child: Text(strings.chooseDestination),
              ),
              FilledButton(
                key: const Key('secure-mesh-file-sync-prepare'),
                onPressed:
                    projection.busy ||
                        draft == null ||
                        draft.destinationLabel.isEmpty ||
                        draft.awaitsConfirmation
                    ? null
                    : () => intents.send(const PrepareRelayTransfer()),
                child: Text(strings.prepareFileSync),
              ),
            ],
          ),
          if (draft != null) ...[
            const SizedBox(height: 14),
            _InfoLine(label: strings.file, value: draft.fileLabel),
            _InfoLine(
              label: strings.fileSyncSize,
              value: '${draft.totalBytes} B / ${draft.chunkCount} chunks',
            ),
            _InfoLine(
              label: strings.destination,
              value: draft.destinationLabel.isEmpty
                  ? strings.notSelected
                  : draft.destinationLabel,
            ),
            _InfoLine(
              label: strings.status,
              value: _statusLabel(strings, draft.stateLabel),
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
                  onPressed: projection.busy
                      ? null
                      : () =>
                            intents.send(ConfirmRelayTransfer(draft!.id, true)),
                  child: Text(strings.confirmWrite),
                ),
                OutlinedButton(
                  key: const Key('secure-mesh-file-sync-reject'),
                  onPressed: projection.busy
                      ? null
                      : () => intents.send(
                          ConfirmRelayTransfer(draft!.id, false),
                        ),
                  child: Text(strings.rejectWrite),
                ),
              ],
            ),
          ],
          if (projection.transfers.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              strings.fileSyncQueue,
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                color: colors.text,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            for (final transfer in projection.transfers.reversed.take(6))
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text(
                  '${transfer.fileLabel} · ${_statusLabel(strings, transfer.stateLabel)}',
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

  String _statusLabel(LicoStrings strings, String status) {
    return switch (status) {
      'drafting' => strings.fileSyncStatusDrafting,
      'evaluating' => strings.fileSyncStatusEvaluating,
      'awaitingConfirmation' => strings.fileSyncStatusAwaitingConfirmation,
      'confirmed' => strings.fileSyncStatusConfirmed,
      'rejected' => strings.fileSyncStatusRejected,
      _ => strings.fileSyncStatusFailed,
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
