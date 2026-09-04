import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/composition/renderer_intent_trace.dart';
import 'package:licoup/src/contracts/agent_hub.dart';
import 'package:licoup/src/composition/features/semantic_feature_channel.dart';
import 'package:licoup/src/presentation/agent_hub/agent_hub_binding.dart';
import 'package:licoup/src/presentation/agent_hub/agent_hub_effect.dart';
import 'package:licoup/src/presentation/agent_hub/agent_hub_intent.dart';
import 'package:licoup/src/projections/agent_hub/agent_hub_projection_producer.dart';

final class AgentHubFeatureComposition {
  AgentHubFeatureComposition(
    ClientController controller, {
    RendererIntentTraceFactory? beginRendererIntent,
  }) : _controller = controller,
       _beginRendererIntent = beginRendererIntent {
    _projection = AgentHubProjectionProducer(
      controller.agentHubCatalogController,
    );
    _effects = SemanticEffectChannel<AgentHubEffect>();
    _intents = SemanticIntentChannel<AgentHubIntent>(_handleIntent);
    binding = AgentHubBinding(
      projection: _projection,
      intents: _intents,
      effects: _effects,
    );
  }

  final ClientController _controller;
  final RendererIntentTraceFactory? _beginRendererIntent;
  late final AgentHubProjectionProducer _projection;
  late final SemanticEffectChannel<AgentHubEffect> _effects;
  late final SemanticIntentChannel<AgentHubIntent> _intents;
  late final AgentHubBinding binding;
  Future<void>? _disposal;

  Future<void> _handleIntent(AgentHubIntent intent) async {
    final trace = resolveRendererIntentTrace(
      intent.trace,
      _beginRendererIntent,
    );
    try {
      await _dispatchIntent(intent, trace);
    } on Object {
      final entryId = switch (intent) {
        PlanAgentHubEntryInstall(:final entryId) ||
        InstallAgentHubEntry(:final entryId) ||
        UpdateAgentHubEntry(:final entryId) ||
        UninstallAgentHubEntry(:final entryId) ||
        VerifyAgentHubEntry(:final entryId) ||
        RetryAgentHubEntryAction(:final entryId) ||
        OpenAgentHubHomepage(:final entryId) ||
        OpenAgentHubAgent(:final entryId) => entryId,
        RefreshAgentHub() => '',
      };
      _effects.emit(
        AgentHubActionRejected(
          entryId,
          'agent_hub_action_failed',
          trace: trace,
        ),
      );
    }
  }

  Future<void> _dispatchIntent(
    AgentHubIntent intent,
    TraceContext? trace,
  ) async {
    final owner = _controller.agentHubCatalogController;
    switch (intent) {
      case RefreshAgentHub():
        await owner.refresh();
      case PlanAgentHubEntryInstall(
        :final entryId,
        :final channelId,
        :final version,
      ):
        final result = await owner.runLifecycle(
          AgentHubLifecycleAction.plan,
          recipeId: entryId,
          channelId: channelId,
          version: version,
        );
        if (!result.ok) {
          _reject(entryId, result, trace);
        } else {
          _effects.emit(
            AgentHubInstallPlanReady(
              entryId,
              result.events.join('\n'),
              channelId: channelId,
              version: version,
              trace: trace,
            ),
          );
        }
      case InstallAgentHubEntry(
        :final entryId,
        :final channelId,
        :final version,
      ):
        await _install(entryId, channelId, version, trace);
      case UpdateAgentHubEntry(:final entryId):
        await _run(AgentHubLifecycleAction.update, entryId, trace);
      case UninstallAgentHubEntry(:final entryId):
        await _run(AgentHubLifecycleAction.uninstall, entryId, trace);
      case VerifyAgentHubEntry(:final entryId):
        await _run(AgentHubLifecycleAction.verify, entryId, trace);
      case RetryAgentHubEntryAction(:final entryId):
        await _run(AgentHubLifecycleAction.rescan, entryId, trace);
      case OpenAgentHubHomepage(:final entryId):
        final entry = _projection.current.entries
            .where((candidate) => candidate.id == entryId)
            .firstOrNull;
        if (entry == null || entry.homepage.isEmpty) {
          _effects.emit(
            AgentHubActionRejected(
              entryId,
              'agent_hub_homepage_unavailable',
              trace: trace,
            ),
          );
        } else {
          _effects.emit(
            AgentHubExternalOpenRequested(
              entryId,
              entry.homepage,
              trace: trace,
            ),
          );
        }
      case OpenAgentHubAgent(:final entryId):
        _effects.emit(AgentHubAgentOpenRequested(entryId, trace: trace));
    }
  }

  Future<void> _run(
    AgentHubLifecycleAction action,
    String entryId,
    TraceContext? trace, {
    String channelId = '',
    String version = 'latest',
  }) async {
    final owner = _controller.agentHubCatalogController;
    final result = await owner.runLifecycle(
      action,
      recipeId: entryId,
      channelId: channelId,
      version: version,
    );
    if (!result.ok) {
      _reject(entryId, result, trace);
      return;
    }
    _effects.emit(
      AgentHubOperationCompleted(
        entryId,
        _effectKind(action),
        events: result.events,
        trace: trace,
      ),
    );
    await owner.refreshRecipe(entryId);
  }

  Future<void> _install(
    String entryId,
    String channelId,
    String version,
    TraceContext? trace,
  ) async {
    final owner = _controller.agentHubCatalogController;
    final plan = await owner.runLifecycle(
      AgentHubLifecycleAction.plan,
      recipeId: entryId,
      channelId: channelId,
      version: version,
    );
    if (!plan.ok) {
      _reject(entryId, plan, trace);
      return;
    }
    final confirmation = await owner.runLifecycle(
      AgentHubLifecycleAction.confirm,
      recipeId: entryId,
    );
    if (!confirmation.ok) {
      _reject(entryId, confirmation, trace);
      return;
    }
    await _run(
      AgentHubLifecycleAction.install,
      entryId,
      trace,
      channelId: channelId,
      version: version,
    );
  }

  void _reject(
    String entryId,
    AgentHubOperationResult result,
    TraceContext? trace,
  ) {
    final reason = result.nativeStatus.trim().isEmpty
        ? 'agent_hub_${result.action.name}_${result.status.name}'
        : result.nativeStatus;
    _effects.emit(AgentHubActionRejected(entryId, reason, trace: trace));
  }

  Future<void> dispose() => _disposal ??= _dispose();

  Future<void> _dispose() async {
    await _projection.dispose();
    await _effects.dispose();
  }
}

AgentHubOperationEffectKind _effectKind(AgentHubLifecycleAction action) =>
    switch (action) {
      AgentHubLifecycleAction.install => AgentHubOperationEffectKind.install,
      AgentHubLifecycleAction.update => AgentHubOperationEffectKind.update,
      AgentHubLifecycleAction.uninstall =>
        AgentHubOperationEffectKind.uninstall,
      AgentHubLifecycleAction.verify => AgentHubOperationEffectKind.verify,
      AgentHubLifecycleAction.rescan => AgentHubOperationEffectKind.rescan,
      AgentHubLifecycleAction.plan || AgentHubLifecycleAction.confirm =>
        throw StateError('Agent Hub preparation is not a completed operation'),
    };
