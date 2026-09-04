import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/presentation/presentation_semantics.dart';
import 'package:licoup/src/presentation/skill_hub/skill_hub_binding.dart';
import 'package:licoup/src/presentation/skill_hub/skill_hub_effect.dart';
import 'package:licoup/src/presentation/skill_hub/skill_hub_intent.dart';
import 'package:licoup/src/presentation/skill_hub/skill_hub_projection.dart';

final class SkillHubBindingFixture {
  SkillHubBindingFixture({
    required List<SkillProjectionItem> skills,
    PresentationPhase phase = PresentationPhase.ready,
    bool usageAvailable = false,
  }) : _projection = _MutableSkillHubProjectionSource(
         SkillHubProjection(
           skills: skills,
           query: '',
           phase: phase,
           usageAvailable: usageAvailable,
         ),
       ),
       _effects = _SkillHubEffectSource() {
    _intents = _SkillHubIntentSink(_handleIntent);
    binding = SkillHubBinding(
      projection: _projection,
      intents: _intents,
      effects: _effects,
    );
  }

  final _MutableSkillHubProjectionSource _projection;
  final _SkillHubEffectSource _effects;
  late final _SkillHubIntentSink _intents;
  late final SkillHubBinding binding;

  String plannedSkillId = '';
  String plannedPath = '';
  String appliedConfirmation = '';

  List<SkillHubIntent> get receivedIntents => _intents.received;

  void _handleIntent(SkillHubIntent intent) {
    switch (intent) {
      case SearchSkills(:final query):
        _projection.replace(query: query, trace: intent.trace);
      case PreviewSkillRemoval(:final skillId, :final path):
        plannedSkillId = skillId;
        plannedPath = path;
        _effects.emit(
          SkillRemovalPreviewReady(
            skillId,
            path,
            'trash:$skillId:test-plan',
            '',
            trace: intent.trace,
          ),
        );
      case ConfirmSkillRemoval(:final skillId, :final confirmation):
        appliedConfirmation = confirmation;
        _projection.remove(skillId, trace: intent.trace);
        _effects.emit(SkillRemovalCompleted(skillId, trace: intent.trace));
      case RefreshSkillHub() || SetSkillVisual():
        break;
    }
  }

  Future<void> dispose() async {
    await _projection.dispose();
    await _effects.dispose();
  }
}

SkillProjectionItem skillHubFixtureSkill({
  required String id,
  required String name,
  String author = '',
  String description = '',
  String content = '',
  String version = 'local',
  required bool isPublic,
  required String path,
  String iconId = 'plug',
  String colorToken = 'primary',
  int usageCount = 0,
  int windowedUsageCount = 0,
  List<SkillAgentProjection> agents = const <SkillAgentProjection>[],
}) => SkillProjectionItem(
  id: id,
  name: name,
  author: author,
  description: description,
  content: content,
  sourceLabel: '',
  version: version,
  pathLabel: path,
  public: isPublic,
  usageCount: usageCount,
  windowedUsageCount: windowedUsageCount,
  iconId: iconId,
  colorToken: colorToken,
  agents: agents,
);

final class _MutableSkillHubProjectionSource
    implements ProjectionSource<SkillHubProjection> {
  _MutableSkillHubProjectionSource(this._current);

  SkillHubProjection _current;
  final StreamController<ProjectionUpdate<SkillHubProjection>> _changes =
      StreamController<ProjectionUpdate<SkillHubProjection>>.broadcast(
        sync: true,
      );

  @override
  SkillHubProjection get current => _current;

  @override
  Stream<ProjectionUpdate<SkillHubProjection>> get changes => _changes.stream;

  void replace({String? query, TraceContext? trace}) {
    _publish(
      SkillHubProjection(
        skills: _current.skills,
        query: query ?? _current.query,
        phase: _current.phase,
        usageAvailable: _current.usageAvailable,
        notice: _current.notice,
      ),
      trace,
    );
  }

  void remove(String skillId, {TraceContext? trace}) {
    _publish(
      SkillHubProjection(
        skills: _current.skills.where((skill) => skill.id != skillId),
        query: _current.query,
        phase: _current.phase,
        usageAvailable: _current.usageAvailable,
        notice: _current.notice,
      ),
      trace,
    );
  }

  void _publish(SkillHubProjection projection, TraceContext? trace) {
    _current = projection;
    _changes.add(ProjectionUpdate(projection, trace: trace));
  }

  Future<void> dispose() => _changes.close();
}

final class _SkillHubIntentSink implements IntentSink<SkillHubIntent> {
  _SkillHubIntentSink(this._handle);

  final void Function(SkillHubIntent intent) _handle;
  final List<SkillHubIntent> received = <SkillHubIntent>[];

  @override
  void send(SkillHubIntent intent) {
    received.add(intent);
    _handle(intent);
  }
}

final class _SkillHubEffectSource implements EffectSource<SkillHubEffect> {
  final StreamController<SkillHubEffect> _effects =
      StreamController<SkillHubEffect>.broadcast(sync: true);

  @override
  Stream<SkillHubEffect> get effects => _effects.stream;

  void emit(SkillHubEffect effect) => _effects.add(effect);

  Future<void> dispose() => _effects.close();
}
