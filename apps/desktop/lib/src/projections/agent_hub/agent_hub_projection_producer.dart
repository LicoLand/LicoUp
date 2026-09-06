import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/application/features/agent_hub/agent_hub_catalog_controller.dart';
import 'package:licoup/src/application/state/application_signal.dart';
import 'package:licoup/src/contracts/agent_hub.dart';
import 'package:licoup/src/presentation/agent_hub/agent_hub_projection.dart';
import 'package:licoup/src/projections/close_broadcast_controller.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

final class AgentHubProjectionProducer
    implements ProjectionSource<AgentHubProjection> {
  AgentHubProjectionProducer(this._controller)
    : _current = _read(_controller, 0) {
    _subscription = _controller.changes.listen(_handleChange);
  }

  final AgentHubCatalogController _controller;
  final StreamController<ProjectionUpdate<AgentHubProjection>> _changes =
      StreamController<ProjectionUpdate<AgentHubProjection>>.broadcast(
        sync: true,
      );
  late final StreamSubscription<ApplicationChange> _subscription;
  AgentHubProjection _current;
  int _refreshRevision = 0;
  bool _wasBusy = false;
  bool _disposed = false;

  @override
  AgentHubProjection get current => _current;

  @override
  Stream<ProjectionUpdate<AgentHubProjection>> get changes => _changes.stream;

  void _handleChange(ApplicationChange change) {
    if (_disposed) return;
    if (_controller.busy && !_wasBusy) _refreshRevision++;
    _wasBusy = _controller.busy;
    // The controller publishes once after the final entry resolves and again
    // when the enclosing refresh settles. The intermediate all-resolved /
    // still-loading snapshot has no stable visual meaning.
    if (_controller.busy &&
        !_controller.resolving &&
        (_controller.catalog?.recipes.isNotEmpty ?? false)) {
      return;
    }
    final next = _read(_controller, _refreshRevision);
    if (next == _current) return;
    _current = next;
    _changes.add(ProjectionUpdate(next, trace: _trace(change.cause)));
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _subscription.cancel();
    await closeBroadcastController(_changes);
  }

  static AgentHubProjection _read(
    AgentHubCatalogController controller,
    int refreshRevision,
  ) {
    final recipes = controller.catalog?.recipes ?? const [];
    return AgentHubProjection(
      entries: [
        for (final recipe in recipes)
          AgentHubEntryProjection(
            id: recipe.id,
            name: recipe.displayName,
            description: recipe.summary,
            adaptation: switch (recipe.adaptation) {
              AgentHubAdaptationDepth.deep => AgentHubAdaptationProjection.deep,
              AgentHubAdaptationDepth.partial =>
                AgentHubAdaptationProjection.partial,
              AgentHubAdaptationDepth.pendingEvaluation =>
                AgentHubAdaptationProjection.pending,
            },
            installed: recipe.present,
            owned: recipe.isOwned,
            installable: recipe.installable,
            busy: controller.isRecipeResolving(recipe.id),
            primaryAction: recipe.primaryAction,
            actionStateLabel: recipe.lifecycle,
            versionLabel: recipe.versionLabel,
            updateAvailable: recipe.updateAvailable,
            homepage: recipe.homepage,
            channelLabel: recipe.channelChipLabel,
            channels: [
              for (final channel in recipe.pickerChannels)
                AgentHubChannelProjection(
                  id: channel.id,
                  label: channel.chipLabel,
                  versionPolicy: channel.versionPolicy,
                  officialSource: channel.officialSource,
                  commandPreview: channel.commandPreview,
                ),
            ],
          ),
      ],
      phase: controller.failed
          ? PresentationPhase.failed
          : controller.busy
          ? PresentationPhase.loading
          : PresentationPhase.ready,
      refreshRevision: refreshRevision,
      notice: controller.failed
          ? const PresentationNotice(
              id: 'agent-hub-catalog-failure',
              title: 'Agent Hub',
              message: 'Agent Hub catalog failed.',
              severity: PresentationNoticeSeverity.error,
              reasonCode: 'agent_hub_catalog_failed',
            )
          : null,
    );
  }
}

TraceContext? _trace(ApplicationCause? cause) =>
    cause?.traceId == null ? null : TraceContext(traceId: cause!.traceId);
