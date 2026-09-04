import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/application/features/skill_hub/controller/skill_delete_controller.dart';
import 'package:licoup/src/application/features/skill_hub/controller/skill_hub_controller.dart';
import 'package:licoup/src/application/features/skill_hub/controller/skill_usage_controller.dart';
import 'package:licoup/src/application/features/skill_hub/models/skill_agent_compatibility.dart';
import 'package:licoup/src/application/features/skill_hub/models/skill_category_catalog.dart';
import 'package:licoup/src/application/features/targets/controller/target_controller.dart';
import 'package:licoup/src/application/state/application_signal.dart';
import 'package:licoup/src/contracts/skill_usage.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';
import 'package:licoup/src/presentation/skill_hub/skill_hub_projection.dart';
import 'package:licoup/src/projections/close_broadcast_controller.dart';

final class SkillHubProjectionProducer
    implements ProjectionSource<SkillHubProjection> {
  SkillHubProjectionProducer({
    required SkillHubController skillHub,
    required SkillDeleteController deletion,
    required SkillUsageController usage,
    required TargetController targets,
  }) : _skillHub = skillHub,
       _deletion = deletion,
       _usage = usage,
       _targets = targets,
       _current = _read(skillHub, deletion, usage, targets, '') {
    _subscriptions = [
      skillHub.changes.listen(_handleChange),
      deletion.changes.listen(_handleChange),
      usage.changes.listen(_handleChange),
      targets.changes.listen(_handleChange),
    ];
  }

  final SkillHubController _skillHub;
  final SkillDeleteController _deletion;
  final SkillUsageController _usage;
  final TargetController _targets;
  final StreamController<ProjectionUpdate<SkillHubProjection>> _changes =
      StreamController<ProjectionUpdate<SkillHubProjection>>.broadcast(
        sync: true,
      );
  late final List<StreamSubscription<ApplicationChange>> _subscriptions;
  late SkillHubProjection _current;
  String _query = '';
  bool _disposed = false;

  @override
  SkillHubProjection get current => _current;

  @override
  Stream<ProjectionUpdate<SkillHubProjection>> get changes => _changes.stream;

  void updateQuery(String query, {TraceContext? trace}) {
    final normalized = query.trimLeft();
    if (_query == normalized || _disposed) return;
    _query = normalized;
    _publish(trace: trace);
  }

  void _handleChange(ApplicationChange change) {
    _publish(trace: _trace(change.cause));
  }

  void _publish({TraceContext? trace}) {
    if (_disposed) return;
    final next = _read(_skillHub, _deletion, _usage, _targets, _query);
    if (next == _current) return;
    _current = next;
    _changes.add(ProjectionUpdate(next, trace: trace));
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final subscription in _subscriptions.reversed) {
      await subscription.cancel();
    }
    await closeBroadcastController(_changes);
  }

  static SkillHubProjection _read(
    SkillHubController skillHub,
    SkillDeleteController deletion,
    SkillUsageController usage,
    TargetController targets,
    String query,
  ) {
    final totalCounts = skillUsageTotalsBySkill(usage.report);
    final windowCounts = skillUsageWindowedBySkill(usage.report);
    final detectedIds = targets.targets
        .where((target) => target.visibleInClient)
        .map((target) => target.target)
        .toList(growable: false);
    final failure = [
      skillHub.lastErrorCode,
      deletion.lastErrorCode,
      usage.lastErrorCode,
    ].where((value) => value.isNotEmpty).firstOrNull;
    final busy = skillHub.busy || deletion.busy || usage.busy;
    return SkillHubProjection(
      query: query,
      usageAvailable: usage.report != null,
      phase: failure != null
          ? PresentationPhase.failed
          : busy
          ? PresentationPhase.loading
          : PresentationPhase.ready,
      skills: [
        for (final skill in skillHub.skills)
          _skill(skill, skillHub, detectedIds, totalCounts, windowCounts),
      ],
      notice: failure == null
          ? null
          : PresentationNotice(
              id: 'skill-hub-failure',
              title: 'Skill Hub',
              message: failure,
              severity: PresentationNoticeSeverity.error,
              reasonCode: failure,
            ),
    );
  }

  static SkillProjectionItem _skill(
    Map<String, dynamic> skill,
    SkillHubController controller,
    List<String> detectedIds,
    Map<String, int> totalCounts,
    Map<String, int> windowCounts,
  ) {
    final id = '${skill['skillId'] ?? skill['title'] ?? ''}';
    final name = '${skill['title'] ?? skill['skillId'] ?? ''}';
    final description = '${skill['description'] ?? ''}';
    final path = '${skill['path'] ?? ''}';
    final isPublic = skill['isPublic'] == true;
    final override = controller.preferences.overrideFor(id);
    final usedBy = (skill['usedByAgents'] is List)
        ? (skill['usedByAgents'] as List).map((value) => '$value')
        : const Iterable<String>.empty();
    final loaders =
        (usedBy.isEmpty
                ? skillLoaderAgentIdsForPath(
                    path: path,
                    isPublic: isPublic,
                    detectedAgentIds: detectedIds,
                  )
                : usedBy.map(canonicalSkillAgentId).toList(growable: false))
            .toSet()
            .toList(growable: false);
    final normalizedId = normalizeSkillUsageId(id);
    return SkillProjectionItem(
      id: id,
      name: name,
      author: '${skill['author'] ?? ''}'.trim(),
      description: description,
      content: '${skill['content'] ?? ''}',
      sourceLabel: '${skill['source'] ?? ''}',
      version: '${skill['version'] ?? 'local'}',
      pathLabel: path,
      public: isPublic,
      usageCount: totalCounts[normalizedId] ?? 0,
      windowedUsageCount: windowCounts[normalizedId] ?? 0,
      iconId: resolveSkillIconId(
        skillId: id,
        title: name,
        description: description,
        overrideIconId: override.iconId,
      ),
      colorToken: override.colorToken.trim().isEmpty
          ? 'primary'
          : override.colorToken.trim(),
      agents: [
        for (final agentId in loaders)
          SkillAgentProjection(
            id: agentId,
            label: skillLoaderAgentLabel(agentId),
          ),
      ],
    );
  }
}

TraceContext? _trace(ApplicationCause? cause) =>
    cause?.traceId == null ? null : TraceContext(traceId: cause!.traceId);
