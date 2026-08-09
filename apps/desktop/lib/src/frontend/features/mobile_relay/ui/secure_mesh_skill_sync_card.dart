import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/contracts/generated/secure_mesh.g.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// Skill-sync browser / preview card layered on the existing handoff actions.
class SecureMeshSkillSyncCard extends StatefulWidget {
  const SecureMeshSkillSyncCard({super.key, required this.controller});

  final ClientController controller;

  @override
  State<SecureMeshSkillSyncCard> createState() =>
      _SecureMeshSkillSyncCardState();
}

class _SecureMeshSkillSyncCardState extends State<SecureMeshSkillSyncCard> {
  final _skillIdController = TextEditingController();
  final _versionController = TextEditingController(text: '1.0.0');
  final _sourceAgentController = TextEditingController();
  final _targetAgentController = TextEditingController();
  final _digestController = TextEditingController();
  final _packageNameController = TextEditingController(text: 'skill.zip');
  final _packageSizeController = TextEditingController(text: '1024');

  ClientController get controller => widget.controller;

  @override
  void dispose() {
    _skillIdController.dispose();
    _versionController.dispose();
    _sourceAgentController.dispose();
    _targetAgentController.dispose();
    _digestController.dispose();
    _packageNameController.dispose();
    _packageSizeController.dispose();
    super.dispose();
  }

  void _beginDraft() {
    final size = int.tryParse(_packageSizeController.text.trim()) ?? 0;
    controller.beginSecureMeshSkillSyncDraft(
      skillId: _skillIdController.text,
      version: _versionController.text,
      sourceAgentId: _sourceAgentController.text,
      targetAgentId: _targetAgentController.text,
      packageDigest: _digestController.text,
      packageFileName: _packageNameController.text,
      packageSize: size,
    );
  }

  Future<void> _pickDestination() async {
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
    final draft = controller.secureMeshSkillSyncDraft;
    final busy = controller.isMobileRelayBusy;
    final transfers = controller.secureMeshSkillSyncTransfers;
    final targets = controller.scannedTargets
        .map((target) => target.id.trim())
        .where((id) => id.isNotEmpty)
        .toList(growable: false);

    return Container(
      key: const Key('secure-mesh-skill-sync-card'),
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
            strings.skillSync,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: colors.text,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            strings.skillSyncHint,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: colors.textMuted),
          ),
          const SizedBox(height: 14),
          _Field(
            keyName: 'secure-mesh-skill-sync-skill-id',
            label: strings.skillId,
            controller: _skillIdController,
          ),
          _Field(
            keyName: 'secure-mesh-skill-sync-version',
            label: strings.version,
            controller: _versionController,
          ),
          _Field(
            keyName: 'secure-mesh-skill-sync-source-agent',
            label: strings.sourceAgent,
            controller: _sourceAgentController,
          ),
          if (targets.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              strings.targetAgent,
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: colors.textMuted),
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final targetId in targets.take(8))
                  ChoiceChip(
                    key: Key('secure-mesh-skill-sync-target-$targetId'),
                    label: Text(targetId),
                    selected: _targetAgentController.text.trim() == targetId,
                    onSelected: busy
                        ? null
                        : (_) {
                            setState(() {
                              _targetAgentController.text = targetId;
                            });
                          },
                  ),
              ],
            ),
          ],
          _Field(
            keyName: 'secure-mesh-skill-sync-target-agent',
            label: strings.targetAgent,
            controller: _targetAgentController,
          ),
          _Field(
            keyName: 'secure-mesh-skill-sync-digest',
            label: strings.packageDigest,
            controller: _digestController,
          ),
          _Field(
            keyName: 'secure-mesh-skill-sync-package-name',
            label: strings.file,
            controller: _packageNameController,
          ),
          _Field(
            keyName: 'secure-mesh-skill-sync-package-size',
            label: strings.fileSyncSize,
            controller: _packageSizeController,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              FilledButton.tonal(
                key: const Key('secure-mesh-skill-sync-begin'),
                onPressed: busy ? null : _beginDraft,
                child: Text(strings.skillSync),
              ),
              OutlinedButton(
                key: const Key('secure-mesh-skill-sync-destination'),
                onPressed: busy || draft == null ? null : _pickDestination,
                child: Text(strings.chooseDestination),
              ),
              FilledButton(
                key: const Key('secure-mesh-skill-sync-prepare'),
                onPressed:
                    busy ||
                        draft == null ||
                        (controller
                                .secureMeshFileSyncDraft
                                ?.destinationRoot
                                .isEmpty ??
                            true) ||
                        draft.status ==
                            SecureMeshSkillSyncStatus.awaitingInstall
                    ? null
                    : controller.prepareSecureMeshSkillSyncTransfer,
                child: Text(strings.skillSyncPrepare),
              ),
            ],
          ),
          if (draft != null) ...[
            const SizedBox(height: 14),
            _InfoLine(label: strings.skillId, value: draft.skillId),
            _InfoLine(label: strings.sourceAgent, value: draft.sourceAgentId),
            _InfoLine(label: strings.targetAgent, value: draft.targetAgentId),
            _InfoLine(label: strings.packageDigest, value: draft.packageDigest),
            _InfoLine(
              label: strings.destination,
              value:
                  controller.secureMeshFileSyncDraft?.destinationRoot.isEmpty ??
                      true
                  ? strings.notSelected
                  : controller.secureMeshFileSyncDraft!.destinationRoot,
            ),
            _InfoLine(
              label: strings.status,
              value: _statusLabel(strings, draft.status),
            ),
          ],
          if (draft?.status == SecureMeshSkillSyncStatus.awaitingInstall) ...[
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                FilledButton(
                  key: const Key('secure-mesh-skill-sync-confirm'),
                  onPressed: busy
                      ? null
                      : () => controller.confirmSecureMeshSkillSyncInstall(
                          userConfirmed: true,
                        ),
                  child: Text(strings.skillSyncConfirmInstall),
                ),
                OutlinedButton(
                  key: const Key('secure-mesh-skill-sync-reject'),
                  onPressed: busy
                      ? null
                      : () => controller.confirmSecureMeshSkillSyncInstall(
                          userConfirmed: false,
                        ),
                  child: Text(strings.skillSyncRejectInstall),
                ),
              ],
            ),
          ],
          if (transfers.isNotEmpty) ...[
            const SizedBox(height: 16),
            Text(
              strings.skillSyncQueue,
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
                  '${transfer.skillId} → ${transfer.targetAgentId} · ${_statusLabel(strings, transfer.status)}',
                  key: Key('secure-mesh-skill-sync-queue-${transfer.id}'),
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

  String _statusLabel(LicoStrings strings, SecureMeshSkillSyncStatus status) {
    return switch (status) {
      SecureMeshSkillSyncStatus.drafting => strings.skillSyncStatusDrafting,
      SecureMeshSkillSyncStatus.transferring =>
        strings.skillSyncStatusTransferring,
      SecureMeshSkillSyncStatus.awaitingInstall =>
        strings.skillSyncStatusAwaitingInstall,
      SecureMeshSkillSyncStatus.installing => strings.skillSyncStatusInstalling,
      SecureMeshSkillSyncStatus.installed => strings.skillSyncStatusInstalled,
      SecureMeshSkillSyncStatus.failed => strings.skillSyncStatusFailed,
    };
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.keyName,
    required this.label,
    required this.controller,
  });

  final String keyName;
  final String label;
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: TextField(
        key: Key(keyName),
        controller: controller,
        decoration: InputDecoration(
          labelText: label,
          labelStyle: TextStyle(color: colors.textMuted),
          isDense: true,
        ),
      ),
    );
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
