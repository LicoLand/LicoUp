/// The project collaboration document source the graph renderer consumes.
///
/// The source admits whole `licoup.ui.graph-resource.v1` revisions and declares,
/// per revision, which node identities changed and whether topology moved. The
/// native producer will publish the same facts; until it does, a synthetic
/// projector can feed the identical contract, so the interface is developed and
/// verified against the real shape rather than a mock of it.
library;

import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_runtime/presentation_runtime.dart';

/// Resource scope of the one project collaboration graph.
const ResourceScope projectCollaborationGraphScope = ResourceScope(
  'licoup.project-collaboration.graph',
);

/// Stable key of the multi-project graph inside that scope.
const String projectCollaborationGraphKey = 'projects';

/// The document source of the project collaboration graph.
final class ProjectCollaborationDocumentSource
    implements PresentationSource<GraphDocumentUpdate> {
  ProjectCollaborationDocumentSource({
    ResourceScope scope = projectCollaborationGraphScope,
    String stableKey = projectCollaborationGraphKey,
    String epochId = 'project-collaboration',
  }) : _epochId = epochId,
       fieldGroup = graphDocumentFieldGroupFor(
         ResourceKey(scope: scope, stableKey: stableKey),
       );

  @override
  final ResourceFieldGroup<GraphDocumentUpdate> fieldGroup;

  /// Identity of this incarnation. A reconnect publishes a new incarnation, so
  /// the runtime admits its first revision instead of treating it as an older
  /// or repeated position inside the previous epoch.
  String _epochId;

  final StreamController<SourceChange<GraphDocumentUpdate>> _changes =
      StreamController<SourceChange<GraphDocumentUpdate>>.broadcast(sync: true);
  ResourceSnapshot<GraphDocumentUpdate>? _current;
  bool _closed = false;

  /// The revision the source currently holds, or null before the first seed.
  ResourceSnapshot<GraphDocumentUpdate>? get snapshot => _current;

  /// Seeds the first revision before any consumer opens the source.
  void seed(
    GraphResourceValue document, {
    Set<String>? changedNodeIds,
    bool topologyChanged = true,
  }) {
    if (_current != null) {
      throw StateError('project collaboration source is already seeded');
    }
    _current = _snapshot(
      document: document,
      changedNodeIds: changedNodeIds,
      topologyChanged: topologyChanged,
      previous: null,
    );
  }

  /// Publishes one later revision.
  bool publish(
    GraphResourceValue document, {
    Set<String>? changedNodeIds,
    bool topologyChanged = false,
  }) {
    if (_closed || _current == null) return false;
    final previous = _current!;
    final next = _snapshot(
      document: document,
      changedNodeIds: changedNodeIds,
      topologyChanged: topologyChanged,
      previous: previous,
    );
    if (previous.value.document.planRevision == document.planRevision) {
      return false;
    }
    _current = next;
    if (_changes.hasListener) {
      _changes.add(
        SourceChange<GraphDocumentUpdate>(
          snapshot: next,
          base: previous.position,
          group: next.consistencyGroup!,
        ),
      );
    }
    return true;
  }

  /// Publishes a fresh incarnation from this same source.
  ///
  /// The runtime keeps one source instance per resource, so a reconnect is this
  /// producer reading again in a new epoch rather than a second producer
  /// claiming the same name. The next revision is a full initial read; callers
  /// that were revoked can observe it normally.
  void reopen({
    required GraphResourceValue document,
    required String epochId,
    Set<String>? changedNodeIds,
  }) {
    if (_closed) return;
    _epochId = epochId;
    _current = _snapshot(
      document: document,
      changedNodeIds: changedNodeIds,
      topologyChanged: true,
      previous: null,
    );
  }

  /// Retires the source: no further revision is admitted.
  void retire() {
    if (_closed) return;
    _closed = true;
    unawaited(_changes.close());
  }

  @override
  Future<SourceObservation<GraphDocumentUpdate>> open() async {
    final current = _current;
    if (current == null) {
      throw StateError('project collaboration source has no revision to open');
    }
    return SourceObservation<GraphDocumentUpdate>(
      initial: current,
      changes: _changes.stream,
    );
  }

  ResourceSnapshot<GraphDocumentUpdate> _snapshot({
    required GraphResourceValue document,
    required Set<String>? changedNodeIds,
    required bool topologyChanged,
    required ResourceSnapshot<GraphDocumentUpdate>? previous,
  }) {
    final epoch = previous?.epoch ?? SourceEpoch(_epochId);
    final version = SourceVersion(
      previous == null ? 1 : previous.version.value + 1,
    );
    final position = SourcePosition(epoch: epoch, version: version);
    final group = ConsistencyGroup(
      id: ConsistencyGroupId(
        'project-collaboration:${document.planRevision}',
        source: SourceIdentity(
          scope: fieldGroup.resource.scope,
          stableKey: fieldGroup.resource.stableKey,
        ),
      ),
      position: position,
      changed: <ChangedFieldGroup>[ChangedFieldGroup.of(fieldGroup)],
    );
    return ResourceSnapshot<GraphDocumentUpdate>(
      fieldGroup: fieldGroup,
      epoch: epoch,
      version: version,
      value: GraphDocumentUpdate(
        document: document,
        changedNodeIds: changedNodeIds,
        topologyChanged: topologyChanged,
      ),
      consistencyGroup: group,
    );
  }
}
