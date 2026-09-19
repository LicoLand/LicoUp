import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/presentation/agent_hub/agent_hub_intent.dart';
import 'package:licoup/src/presentation/agent_hub/agent_hub_projection.dart';
import 'package:licoup/src/presentation/agent_hub/agent_hub_resources.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

/// Narrow renderer-facing inputs for the agent hub catalog view.
final class AgentHubCatalogInputs {
  const AgentHubCatalogInputs({
    required this.scope,
    required this.entries,
    required this.phase,
    required this.refreshRevision,
    this.notice,
  });

  factory AgentHubCatalogInputs.fromProjection(AgentHubProjection projection) =>
      AgentHubCatalogInputs(
        scope: agentHubPresentationScope,
        entries: projection.entries,
        phase: projection.phase,
        refreshRevision: projection.refreshRevision,
        notice: projection.notice,
      );

  final ResourceScope scope;
  final List<AgentHubEntryProjection> entries;
  final PresentationPhase phase;
  final int refreshRevision;
  final PresentationNotice? notice;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AgentHubCatalogInputs &&
          other.scope == scope &&
          samePresentationList(other.entries, entries) &&
          other.phase == phase &&
          other.refreshRevision == refreshRevision &&
          other.notice == notice;

  @override
  int get hashCode => Object.hash(
    scope,
    Object.hashAll(entries),
    phase,
    refreshRevision,
    notice,
  );
}

/// Narrow renderer actions for the agent hub catalog. Every dispatch carries
/// the pinned originating scope so asynchronous failures stay attributable.
final class AgentHubCatalogActions {
  const AgentHubCatalogActions({
    required this.origin,
    required this.refresh,
    required this.planEntryInstall,
    required this.installEntry,
    required this.updateEntry,
    required this.uninstallEntry,
    required this.verifyEntry,
    required this.retryEntryAction,
    required this.openEntryHomepage,
    required this.openEntryAgent,
  });

  factory AgentHubCatalogActions.fromIntents(
    IntentSink<AgentHubIntent> intents,
  ) {
    const origin = ActionOrigin(
      scope: agentHubPresentationScope,
      resource: agentHubCatalogResource,
    );
    final channel = CallbackActions<AgentHubIntent>(
      origin: origin,
      onDispatch: (intent, _) => intents.send(intent),
    );
    return AgentHubCatalogActions(
      origin: origin,
      refresh: () => channel.dispatch(const RefreshAgentHub()),
      planEntryInstall:
          (entryId, {String channelId = '', String version = 'latest'}) =>
              channel.dispatch(
                PlanAgentHubEntryInstall(
                  entryId,
                  channelId: channelId,
                  version: version,
                ),
              ),
      installEntry:
          (entryId, {String channelId = '', String version = 'latest'}) =>
              channel.dispatch(
                InstallAgentHubEntry(
                  entryId,
                  channelId: channelId,
                  version: version,
                ),
              ),
      updateEntry: (entryId) => channel.dispatch(UpdateAgentHubEntry(entryId)),
      uninstallEntry: (entryId) =>
          channel.dispatch(UninstallAgentHubEntry(entryId)),
      verifyEntry: (entryId) => channel.dispatch(VerifyAgentHubEntry(entryId)),
      retryEntryAction: (entryId) =>
          channel.dispatch(RetryAgentHubEntryAction(entryId)),
      openEntryHomepage: (entryId) =>
          channel.dispatch(OpenAgentHubHomepage(entryId)),
      openEntryAgent: (entryId) => channel.dispatch(OpenAgentHubAgent(entryId)),
    );
  }

  final ActionOrigin origin;
  final FutureOr<void> Function() refresh;
  final FutureOr<void> Function(
    String entryId, {
    String channelId,
    String version,
  })
  planEntryInstall;
  final FutureOr<void> Function(
    String entryId, {
    String channelId,
    String version,
  })
  installEntry;
  final FutureOr<void> Function(String entryId) updateEntry;
  final FutureOr<void> Function(String entryId) uninstallEntry;
  final FutureOr<void> Function(String entryId) verifyEntry;
  final FutureOr<void> Function(String entryId) retryEntryAction;
  final FutureOr<void> Function(String entryId) openEntryHomepage;
  final FutureOr<void> Function(String entryId) openEntryAgent;
}
