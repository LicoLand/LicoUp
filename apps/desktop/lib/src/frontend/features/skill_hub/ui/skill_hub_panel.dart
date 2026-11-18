import 'dart:async';

import 'package:flutter/material.dart';

import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_flutter/presentation_flutter.dart';

import 'package:licoup/src/frontend/binding/effect_listener.dart';
import 'package:licoup/src/frontend/features/skill_hub/ui/skill_hub_panel_catalog.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/lico_pane_scaffold.dart';
import 'package:licoup/src/frontend/shared/ui/lico_toast.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';
import 'package:licoup/src/presentation/skill_hub/skill_hub_binding.dart';
import 'package:licoup/src/presentation/skill_hub/skill_hub_effect.dart';
import 'package:licoup/src/presentation/skill_hub/skill_hub_inputs.dart';
import 'package:licoup/src/presentation/skill_hub/skill_hub_intent.dart';
import 'package:licoup/src/presentation/skill_hub/skill_hub_providers.dart';

export 'package:licoup/src/frontend/features/skill_hub/ui/skill_hub_panel_icon_picker.dart'
    show SkillCategoryIconBadge, resolveSkillIconColor, showSkillIconPicker;

class SkillHubPanel extends StatefulWidget {
  const SkillHubPanel({
    super.key,
    required this.binding,
    this.agentId,
    this.embedded = false,
  });

  final SkillHubBinding binding;
  final String? agentId;
  final bool embedded;

  @override
  State<SkillHubPanel> createState() => _SkillHubPanelState();
}

class _SkillHubPanelState extends State<SkillHubPanel> {
  String _category = 'all';
  final Map<String, String> _skillNames = <String, String>{};

  @override
  Widget build(BuildContext context) {
    return EffectListener<SkillHubEffect>(
      source: widget.binding.effects,
      onEffect: _handleEffect,
      child: AsyncRegion<SkillHubCatalogInputs, IntentSink<SkillHubIntent>>(
        source: skillHubCatalogInputsProvider,
        actions: widget.binding.intents,
        loading: (_, _) => const SizedBox.shrink(),
        data: (context, inputs, _) => _buildCatalog(context, inputs),
      ),
    );
  }

  Widget _buildCatalog(BuildContext context, SkillHubCatalogInputs inputs) {
    for (final skill in inputs.skills) {
      _skillNames[skill.id] = skill.name;
    }
    final body = CustomScrollView(
      slivers: [
        if (inputs.phase == PresentationPhase.failed &&
            inputs.skills.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                LicoStrings.of(context).isChinese
                    ? '技能刷新失败，请重试。'
                    : 'Skills could not be refreshed. Try again.',
                key: const Key('skill-hub-refresh-failed'),
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          ),
        SliverToBoxAdapter(
          child: SkillCategoryFilter(
            selectedCategory: _category,
            onChanged: (value) => setState(() => _category = value),
          ),
        ),
        SkillCollection(
          inputs: inputs,
          intents: widget.binding.intents,
          selectedCategory: _category,
          agentId: widget.agentId,
        ),
      ],
    );
    if (widget.embedded) return body;
    return LicoPaneScaffold(
      title: LicoStrings.of(context).skillHub,
      refreshTooltip: LicoStrings.of(context).refreshSkills,
      onRefresh: inputs.phase == PresentationPhase.loading
          ? null
          : () => widget.binding.intents.send(const RefreshSkillHub()),
      refreshing: inputs.phase == PresentationPhase.loading,
      refreshButtonKey: const Key('skill-hub-refresh'),
      body: body,
    );
  }

  void _handleEffect(SkillHubEffect effect) {
    switch (effect) {
      case SkillRemovalPreviewReady():
        unawaited(_confirmRemoval(effect));
      case SkillRemovalCompleted():
        final displayName = _skillNames[effect.skillId] ?? effect.skillId;
        showLicoToast(
          context,
          message: LicoStrings.of(context).skillMovedToSystemTrash(displayName),
          kind: LicoToastKind.success,
        );
      case SkillHubActionRejected():
        showLicoToast(
          context,
          message: LicoStrings.of(context).skillTrashFailed,
          kind: LicoToastKind.error,
        );
    }
  }

  Future<void> _confirmRemoval(SkillRemovalPreviewReady effect) async {
    final displayName = _skillNames[effect.skillId] ?? effect.skillId;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(LicoStrings.of(dialogContext).deleteSkillTitle),
        content: Text(
          LicoStrings.of(dialogContext).trashSkillMessage(displayName),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(LicoStrings.of(dialogContext).cancel),
          ),
          FilledButton(
            key: const Key('skill-move-to-trash-confirm'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(LicoStrings.of(dialogContext).moveToSystemTrash),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      widget.binding.intents.send(
        ConfirmSkillRemoval(
          effect.skillId,
          effect.path,
          effect.confirmation,
          trace: effect.trace,
        ),
      );
    }
  }
}
