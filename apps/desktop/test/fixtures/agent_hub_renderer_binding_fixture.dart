import 'dart:async';

import 'package:licoup/src/application/features/agent_hub/agent_hub_catalog_controller.dart';
import 'package:licoup/src/contracts/agent_hub.dart';
import 'package:licoup/src/composition/features/semantic_feature_channel.dart';
import 'package:licoup/src/presentation/agent_hub/agent_hub_binding.dart';
import 'package:licoup/src/presentation/agent_hub/agent_hub_effect.dart';
import 'package:licoup/src/presentation/agent_hub/agent_hub_intent.dart';
import 'package:licoup/src/projections/agent_hub/agent_hub_projection_producer.dart';

/// Test-only semantic assembly for Agent Hub renderer fixtures with an
/// injected native engine.
final class AgentHubRendererBindingFixture {
  AgentHubRendererBindingFixture(this._owner) {
    _projection = AgentHubProjectionProducer(_owner);
    _effects = SemanticEffectChannel<AgentHubEffect>();
    _intents = SemanticIntentChannel<AgentHubIntent>(_handleIntent);
    binding = AgentHubBinding(
      projection: _projection,
      intents: _intents,
      effects: _effects,
    );
  }

  final AgentHubCatalogController _owner;
  late final AgentHubProjectionProducer _projection;
  late final SemanticEffectChannel<AgentHubEffect> _effects;
  late final SemanticIntentChannel<AgentHubIntent> _intents;
  late final AgentHubBinding binding;
  Future<void>? _disposal;

  Future<void> _handleIntent(AgentHubIntent intent) async {
    switch (intent) {
      case RefreshAgentHub():
        await _owner.refresh();
      case PlanAgentHubEntryInstall(
        :final entryId,
        :final channelId,
        :final version,
      ):
        final result = await _owner.runLifecycle(
          AgentHubLifecycleAction.plan,
          recipeId: entryId,
          channelId: channelId,
          version: version,
        );
        if (result.ok) {
          _effects.emit(
            AgentHubInstallPlanReady(
              entryId,
              result.events.join('\n'),
              channelId: channelId,
              version: version,
              trace: intent.trace,
            ),
          );
        }
      case InstallAgentHubEntry(
        :final entryId,
        :final channelId,
        :final version,
      ):
        await _install(entryId, channelId, version, intent);
      case UpdateAgentHubEntry(:final entryId):
        await _run(AgentHubLifecycleAction.update, entryId, intent: intent);
      case UninstallAgentHubEntry(:final entryId):
        await _run(AgentHubLifecycleAction.uninstall, entryId, intent: intent);
      case VerifyAgentHubEntry(:final entryId):
        await _run(AgentHubLifecycleAction.verify, entryId, intent: intent);
      case RetryAgentHubEntryAction(:final entryId):
        await _run(AgentHubLifecycleAction.rescan, entryId, intent: intent);
      case OpenAgentHubHomepage(:final entryId):
        final entry = _projection.current.entries
            .where((candidate) => candidate.id == entryId)
            .firstOrNull;
        if (entry != null && entry.homepage.isNotEmpty) {
          _effects.emit(
            AgentHubExternalOpenRequested(
              entryId,
              entry.homepage,
              trace: intent.trace,
            ),
          );
        }
      case OpenAgentHubAgent(:final entryId):
        _effects.emit(AgentHubAgentOpenRequested(entryId, trace: intent.trace));
    }
  }

  Future<void> _run(
    AgentHubLifecycleAction action,
    String entryId, {
    AgentHubIntent? intent,
    String channelId = '',
    String version = 'latest',
  }) async {
    final result = await _owner.runLifecycle(
      action,
      recipeId: entryId,
      channelId: channelId,
      version: version,
    );
    if (!result.ok) {
      _effects.emit(
        AgentHubActionRejected(
          entryId,
          result.nativeStatus,
          trace: intent?.trace,
        ),
      );
      return;
    }
    _effects.emit(
      AgentHubOperationCompleted(
        entryId,
        _effectKind(action),
        events: result.events,
        trace: intent?.trace,
      ),
    );
    await _owner.refreshRecipe(entryId);
  }

  Future<void> _install(
    String entryId,
    String channelId,
    String version,
    AgentHubIntent intent,
  ) async {
    final plan = await _owner.runLifecycle(
      AgentHubLifecycleAction.plan,
      recipeId: entryId,
      channelId: channelId,
      version: version,
    );
    if (!plan.ok) {
      _reject(entryId, plan, intent);
      return;
    }
    final confirmation = await _owner.runLifecycle(
      AgentHubLifecycleAction.confirm,
      recipeId: entryId,
    );
    if (!confirmation.ok) {
      _reject(entryId, confirmation, intent);
      return;
    }
    await _run(
      AgentHubLifecycleAction.install,
      entryId,
      intent: intent,
      channelId: channelId,
      version: version,
    );
  }

  void _reject(
    String entryId,
    AgentHubOperationResult result,
    AgentHubIntent intent,
  ) {
    final reason = result.nativeStatus.trim().isEmpty
        ? 'agent_hub_${result.action.name}_${result.status.name}'
        : result.nativeStatus;
    _effects.emit(AgentHubActionRejected(entryId, reason, trace: intent.trace));
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
