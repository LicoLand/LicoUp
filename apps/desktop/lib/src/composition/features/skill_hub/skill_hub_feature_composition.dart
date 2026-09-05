import 'dart:async';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/composition/features/semantic_feature_channel.dart';
import 'package:licoup/src/composition/renderer_intent_trace.dart';
import 'package:licoup/src/presentation/skill_hub/skill_hub_binding.dart';
import 'package:licoup/src/presentation/skill_hub/skill_hub_effect.dart';
import 'package:licoup/src/presentation/skill_hub/skill_hub_intent.dart';
import 'package:licoup/src/projections/skill_hub/skill_hub_projection_producer.dart';

final class SkillHubFeatureComposition {
  SkillHubFeatureComposition(
    ClientController controller, {
    RendererIntentTraceFactory? beginRendererIntent,
  }) : _controller = controller,
       _beginRendererIntent = beginRendererIntent {
    _projection = SkillHubProjectionProducer(
      skillHub: controller.skillHubController,
      deletion: controller.skillDeleteController,
      usage: controller.skillUsageController,
      targets: controller.targetController,
    );
    _effects = SemanticEffectChannel<SkillHubEffect>();
    _intents = SemanticIntentChannel<SkillHubIntent>(_handleIntent);
    binding = SkillHubBinding(
      projection: _projection,
      intents: _intents,
      effects: _effects,
    );
  }

  final ClientController _controller;
  final RendererIntentTraceFactory? _beginRendererIntent;
  late final SkillHubProjectionProducer _projection;
  late final SemanticEffectChannel<SkillHubEffect> _effects;
  late final SemanticIntentChannel<SkillHubIntent> _intents;
  late final SkillHubBinding binding;
  Future<void>? _disposal;

  Future<void> _handleIntent(SkillHubIntent intent) async {
    final trace = resolveRendererIntentTrace(
      intent.trace,
      _beginRendererIntent,
    );
    switch (intent) {
      case RefreshSkillHub(:final agentId):
        unawaited(_controller.skillUsageController.loadCounts());
        await _controller.skillHubController.refresh(
          agentId,
          forceRefresh: true,
        );
      case SearchSkills(:final query):
        _projection.updateQuery(query, trace: trace);
      case PreviewSkillRemoval(:final skillId, :final path):
        await _controller.skillDeleteController.preview(
          skillId: skillId,
          path: path,
        );
        final deletion = _controller.skillDeleteController;
        final plan = deletion.plan;
        final confirmation = '${plan?['confirmation'] ?? ''}';
        if (deletion.lastErrorCode.isNotEmpty ||
            plan?['ok'] != true ||
            plan?['trashAllowed'] != true ||
            confirmation.isEmpty) {
          _effects.emit(
            SkillHubActionRejected(
              deletion.lastErrorCode.isEmpty
                  ? 'skill_delete_plan_failed'
                  : deletion.lastErrorCode,
              trace: trace,
            ),
          );
          return;
        }
        _effects.emit(
          SkillRemovalPreviewReady(
            skillId,
            path,
            confirmation,
            '${plan?['summary'] ?? ''}',
            trace: trace,
          ),
        );
      case ConfirmSkillRemoval(
        :final skillId,
        :final path,
        :final confirmation,
      ):
        await _controller.skillDeleteController.apply(
          skillId: skillId,
          path: path,
          confirmation: confirmation,
        );
        final deletion = _controller.skillDeleteController;
        if (deletion.lastErrorCode.isNotEmpty ||
            deletion.actionResult?['ok'] != true ||
            deletion.actionResult?['status'] != 'trashed') {
          _effects.emit(
            SkillHubActionRejected(
              deletion.lastErrorCode.isEmpty
                  ? 'skill_delete_apply_failed'
                  : deletion.lastErrorCode,
              trace: trace,
            ),
          );
          return;
        }
        _controller.skillHubController.removeSkillAtPath(path);
        _effects.emit(SkillRemovalCompleted(skillId, trace: trace));
      case SetSkillVisual(:final skillId, :final iconId, :final colorToken):
        await _controller.skillHubController.updateVisualOverride(
          skillId: skillId,
          iconId: iconId,
          colorToken: colorToken,
        );
    }
  }

  Future<void> dispose() => _disposal ??= _dispose();

  Future<void> _dispose() async {
    await _projection.dispose();
    await _effects.dispose();
  }
}
