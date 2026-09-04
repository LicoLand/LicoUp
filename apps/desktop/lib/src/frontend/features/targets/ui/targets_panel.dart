import 'dart:async';

import 'package:flutter/material.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/frontend/binding/effect_listener.dart';
import 'package:licoup/src/frontend/binding/projection_builder.dart';
import 'package:licoup/src/frontend/features/targets/ui/manual_target_dialog.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/lico_empty_state.dart';
import 'package:licoup/src/frontend/shared/ui/lico_pane_scaffold.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';
import 'package:licoup/src/presentation/targets/targets_binding.dart';
import 'package:licoup/src/presentation/targets/targets_effect.dart';
import 'package:licoup/src/presentation/targets/targets_intent.dart';
import 'package:licoup/src/presentation/targets/targets_projection.dart';

final class TargetsPanel extends StatelessWidget {
  const TargetsPanel({super.key, required this.binding, this.onOpenDirectory});

  final TargetsBinding binding;
  final FutureOr<void> Function(String path)? onOpenDirectory;

  @override
  Widget build(BuildContext context) {
    return EffectListener<TargetsEffect>(
      source: binding.effects,
      onEffect: (effect) => _handleEffect(context, effect),
      child: ProjectionBuilder<TargetsProjection, TargetsProjection>(
        source: binding.projection,
        select: (projection) => projection,
        builder: (context, projection) => LicoPaneScaffold(
          key: const Key('targets-panel'),
          title: LicoStrings.of(context).target,
          refreshTooltip: LicoStrings.of(context).refresh,
          onRefresh: projection.phase == PresentationPhase.loading
              ? null
              : () => binding.intents.send(const ScanTargets(force: true)),
          refreshing: projection.phase == PresentationPhase.loading,
          refreshButtonKey: const Key('targets-refresh'),
          trailing: IconButton(
            key: const Key('targets-add'),
            tooltip: LicoStrings.of(context).addTarget,
            onPressed: projection.phase == PresentationPhase.loading
                ? null
                : () => unawaited(_addTarget(context)),
            icon: const Icon(Icons.add),
          ),
          body: projection.targets.isEmpty
              ? LicoEmptyState(
                  icon: Icons.smart_toy_outlined,
                  title: LicoStrings.of(context).target,
                  message: LicoStrings.of(context).isChinese
                      ? '尚未发现智能体目标。'
                      : 'No agent targets were discovered.',
                )
              : ListView.separated(
                  itemCount: projection.targets.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (context, index) => _TargetProjectionCard(
                    target: projection.targets[index],
                    intents: binding.intents,
                  ),
                ),
        ),
      ),
    );
  }

  Future<void> _addTarget(BuildContext context) async {
    final draft = await showDialog<ManualTargetDraft>(
      context: context,
      builder: (_) => ManualTargetDialog(
        options: binding.projection.current.manualTargetOptions,
        onOpenDirectory: onOpenDirectory,
      ),
    );
    if (draft == null) return;
    final runtime = draft.runtimeConnection;
    binding.intents.send(
      AddManualTarget(
        targetId: draft.target,
        configPath: draft.configPath,
        binaryPath: draft.binaryPath,
        historyRoot: draft.historyRoot,
        location: draft.location,
        host: '${runtime['host'] ?? ''}',
        port: runtime['port'] is int ? runtime['port'] as int : null,
        user: '${runtime['user'] ?? ''}',
        remoteExecutable: '${runtime['remoteExecutable'] ?? ''}',
        workingDirectory: '${runtime['workingDirectory'] ?? ''}',
        runtimeProtocol: '${runtime['runtimeProtocol'] ?? ''}',
      ),
    );
  }

  void _handleEffect(BuildContext context, TargetsEffect effect) {
    switch (effect) {
      case TargetInspectionReady():
        unawaited(
          showDialog<void>(
            context: context,
            builder: (dialogContext) => AlertDialog(
              key: const Key('target-inspection-dialog'),
              title: Text(effect.targetId),
              content: SingleChildScrollView(
                child: SelectableText(effect.summary),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext),
                  child: Text(LicoStrings.of(dialogContext).close),
                ),
              ],
            ),
          ),
        );
      case TargetActionRejected():
        ScaffoldMessenger.maybeOf(
          context,
        )?.showSnackBar(SnackBar(content: Text(effect.reasonCode)));
    }
  }
}

final class _TargetProjectionCard extends StatelessWidget {
  const _TargetProjectionCard({required this.target, required this.intents});

  final TargetProjectionItem target;
  final IntentSink<TargetsIntent> intents;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return Card(
      key: Key('target-projection-${target.id}'),
      child: ListTile(
        selected: target.selected,
        onTap: () => intents.send(SelectTarget(target.id)),
        leading: Icon(
          target.configured ? Icons.smart_toy : Icons.smart_toy_outlined,
        ),
        title: Text(target.name),
        subtitle: Text(
          [
            target.typeLabel,
            target.readinessLabel,
            if (target.locationLabel != 'local') target.locationLabel,
          ].where((value) => value.isNotEmpty).join(' · '),
        ),
        trailing: Wrap(
          spacing: 4,
          children: [
            IconButton(
              key: Key('target-inspect-${target.id}'),
              tooltip: strings.inspect,
              onPressed: () => intents.send(InspectTarget(target.id)),
              icon: const Icon(Icons.info_outline),
            ),
            IconButton(
              key: Key('target-pin-${target.id}'),
              tooltip: target.pinned
                  ? (strings.isChinese ? '取消固定' : 'Unpin')
                  : (strings.isChinese ? '固定' : 'Pin'),
              color: target.pinned ? colors.primary : null,
              onPressed: () => intents.send(ToggleTargetPinned(target.id)),
              icon: Icon(
                target.pinned ? Icons.push_pin : Icons.push_pin_outlined,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
