import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/features/agents/adaptive_flywheel/adaptive_flywheel_controller.dart';
import 'package:licoup/src/composition/renderer_intent_trace.dart';
import 'package:licoup/src/contracts/adaptive_flywheel_models.dart';
import 'package:licoup/src/contracts/client_conversation_models.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/presentation/agents/agents_binding.dart';
import 'package:licoup/src/presentation/agents/agents_effect.dart';
import 'package:licoup/src/presentation/agents/agents_intent.dart';
import 'package:licoup/src/presentation/agents/adaptive_flywheel_projection.dart';
import 'package:licoup/src/projections/agents/agents_projection_producer.dart';
import 'package:licoup/src/projections/close_broadcast_controller.dart';

final class AgentsFeatureComposition {
  AgentsFeatureComposition(
    ClientController controller, {
    RendererIntentTraceFactory? beginRendererIntent,
  }) {
    _adaptiveFlywheel = AdaptiveFlywheelController(
      gateway: controller.adaptiveFlywheelGateway,
    );
    _effects = _AgentsEffects();
    _projection = AgentsProjectionProducer(
      controller,
      adaptiveFlywheel: _adaptiveFlywheel,
    );
    _intents = _AgentsIntents.pending(
      controller,
      beginRendererIntent: beginRendererIntent,
    );
    _intents.attach(
      adaptiveFlywheel: _adaptiveFlywheel,
      projection: _projection,
    );
    _intents.effects = _effects;
    binding = AgentsBinding(
      projection: _projection,
      intents: _intents,
      effects: _effects,
    );
  }

  late final AdaptiveFlywheelController _adaptiveFlywheel;
  late final AgentsProjectionProducer _projection;
  late final _AgentsEffects _effects;
  late final _AgentsIntents _intents;
  late final AgentsBinding binding;
  bool _closed = false;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _projection.close();
    _adaptiveFlywheel.dispose();
    await _effects.close();
  }
}

final class _AgentsEffects implements EffectSource<AgentsEffect> {
  final StreamController<AgentsEffect> _controller =
      StreamController<AgentsEffect>.broadcast(sync: true);

  @override
  Stream<AgentsEffect> get effects => _controller.stream;

  void add(AgentsEffect effect) => _controller.add(effect);

  Future<void> close() => closeBroadcastController(_controller);
}

final class _AgentsIntents implements IntentSink<AgentsIntent> {
  _AgentsIntents.pending(
    this._controller, {
    RendererIntentTraceFactory? beginRendererIntent,
  }) : _beginRendererIntent = beginRendererIntent;

  final ClientController _controller;
  final RendererIntentTraceFactory? _beginRendererIntent;
  late AdaptiveFlywheelController _adaptiveFlywheel;
  late AgentsProjectionProducer _projection;
  late _AgentsEffects effects;
  Map<String, dynamic>? _assistantProfile;
  String _assistantProfileConversationId = '';
  String _assistantProfileMembershipId = '';

  void attach({
    required AdaptiveFlywheelController adaptiveFlywheel,
    required AgentsProjectionProducer projection,
  }) {
    _adaptiveFlywheel = adaptiveFlywheel;
    _projection = projection;
  }

  @override
  void send(AgentsIntent intent) {
    final trace = resolveRendererIntentTrace(
      intent.trace,
      _beginRendererIntent,
    );
    switch (intent) {
      case InitializeAdaptiveFlywheel(:final initialRevision):
        _run(
          () async {
            await Future.wait([
              _adaptiveFlywheel.initialize(),
              _loadAssistantProfile(trace: trace),
            ]);
            if (initialRevision.isNotEmpty &&
                _adaptiveFlywheel.definitions.any(
                  (definition) => definition.revisionDigest == initialRevision,
                ) &&
                _adaptiveFlywheel.selectedRevision != initialRevision) {
              await _adaptiveFlywheel.selectDefinition(initialRevision);
            }
            await _refreshSelectedModelCatalogs();
          },
          trace,
          reasonCode: 'adaptive_flywheel_initialize_failed',
        );
      case ImportAdaptiveFlywheelPackage(:final path):
        if (path.trim().isEmpty) {
          effects.add(
            AdaptiveFlywheelActionRejected(
              'adaptive_flywheel_package_required',
              trace: trace,
            ),
          );
          return;
        }
        _run(
          () => _adaptiveFlywheel.importPackage(path.trim()),
          trace,
          reasonCode: 'adaptive_flywheel_import_failed',
        );
      case SelectAdaptiveFlywheelDefinition(:final revision):
        if (revision.trim().isEmpty) return;
        _run(
          () => _adaptiveFlywheel.selectDefinition(revision.trim()),
          trace,
          reasonCode: 'adaptive_flywheel_selection_failed',
        );
      case SaveAdaptiveFlywheelActorBindings(:final assignments):
        _run(
          () async {
            await _saveActorBindings(assignments, trace: trace);
          },
          trace,
          reasonCode: 'adaptive_flywheel_bindings_save_failed',
        );
      case SaveAdaptiveFlywheelConfiguration(
        :final assignments,
        :final updateAssistant,
        :final assistantAgentId,
        :final assistantModelId,
        :final assistantReasoningEffort,
      ):
        _run(
          () async {
            if (updateAssistant) {
              final updated = await _updateAssistantProfile(
                agentId: assistantAgentId,
                modelId: assistantModelId,
                reasoningEffort: assistantReasoningEffort,
                trace: trace,
                emitCompletion: false,
              );
              if (!updated) return;
            }
            final saved = await _saveActorBindings(
              assignments,
              trace: trace,
              emitCompletion: false,
            );
            if (saved) {
              effects.add(AdaptiveFlywheelConfigurationSaved(trace: trace));
            }
          },
          trace,
          reasonCode: 'adaptive_flywheel_configuration_save_failed',
        );
      case RefreshAdaptiveFlywheelModelCatalogs(:final agentIds):
        _run(
          () => _controller.refreshAgentModelCatalogs(
            agentIds
                .map((id) => id.trim())
                .where((id) => id.isNotEmpty)
                .toSet(),
          ),
          trace,
          reasonCode: 'adaptive_flywheel_model_refresh_failed',
        );
      case ReadAdaptiveFlywheelAssistantProfile():
        _run(
          () => _loadAssistantProfile(trace: trace),
          trace,
          reasonCode: 'adaptive_flywheel_profile_read_failed',
        );
      case UpdateAdaptiveFlywheelAssistantProfile(
        :final agentId,
        :final modelId,
        :final reasoningEffort,
      ):
        _run(
          () async {
            await _updateAssistantProfile(
              agentId: agentId,
              modelId: modelId,
              reasoningEffort: reasoningEffort,
              trace: trace,
            );
          },
          trace,
          reasonCode: 'adaptive_flywheel_profile_update_failed',
        );
      case ScanAgents(:final showProgress, :final forceRescanKnown):
        _run(
          () => _controller.scanTargets(
            showProgress: showProgress,
            forceRescanKnown: forceRescanKnown,
          ),
          trace,
        );
      case SelectAgent(:final agentId):
        _run(() => _controller.selectConversationAgent(agentId), trace);
      case ShowAgentsWelcome():
        _controller.showConversationWelcomePage();
      case SelectAgentConversationSession(
        :final agentId,
        :final sessionId,
        :final nativeSessionId,
      ):
        _run(() async {
          _controller.selectSection(ClientSection.agents);
          _controller.clientConversationController.clearSelection();
          final resolved = _resolveSessionId(
            agentId,
            sessionId,
            nativeSessionId,
          );
          if (_controller.selectedConversationAgentId != agentId) {
            await _controller.selectConversationAgent(agentId);
          }
          if (resolved.isNotEmpty) {
            _controller.selectConversationSession(resolved);
          }
        }, trace);
      case SelectGroupAgentConversationSession(
        :final groupConversationId,
        :final agentId,
        :final sessionId,
        :final nativeSessionId,
      ):
        final selectedGroupId =
            _controller.clientConversationController.selectedConversationId;
        if (selectedGroupId != groupConversationId) {
          effects.add(
            AgentSelectionRejected(
              'canonical_group_selection_changed',
              trace: trace,
            ),
          );
          return;
        }
        _run(() async {
          final resolved = _resolveSessionId(
            agentId,
            sessionId,
            nativeSessionId,
          );
          await _controller.selectConversationAgent(agentId);
          if (_controller.clientConversationController.selectedConversationId !=
              groupConversationId) {
            return;
          }
          if (resolved.isNotEmpty) {
            _controller.selectConversationSession(resolved);
          }
        }, trace);
      case StartAgentConversation(:final agentId):
        _run(() async {
          _controller.clientConversationController.clearSelection();
          await _controller.selectConversationAgent(agentId);
          _controller.startNewConversationSession();
        }, trace);
      case AddManualAgent(
        :final command,
        :final configPath,
        :final binaryPath,
        :final historyRoot,
        :final location,
        :final runtimeConnection,
      ):
        _run(
          () => _controller.addManualTarget(
            target: command,
            configPath: configPath,
            binaryPath: binaryPath,
            historyRoot: historyRoot,
            location: location,
            runtimeConnection: runtimeConnection,
          ),
          trace,
        );
      case ToggleAgentPinned(:final agentId):
        _run(() => _controller.toggleConversationTargetPinned(agentId), trace);
      case SelectAgentWorkingDirectory(:final path):
        final normalized = path.trim();
        if (normalized.isEmpty) {
          effects.add(
            AgentWorkingDirectorySelectionRejected(
              'working_directory_required',
              trace: trace,
            ),
          );
          return;
        }
        _controller.selectNewConversationWorkingDirectory(normalized);
    }
  }

  String _resolveSessionId(
    String agentId,
    String sessionId,
    String nativeSessionId,
  ) {
    final sessions =
        _controller.conversationSessionsByAgent[agentId] ?? const [];
    final normalizedId = sessionId.trim();
    for (final session in sessions) {
      if (session.id == normalizedId) return session.id;
    }
    final normalizedNativeId = nativeSessionId.trim();
    if (normalizedNativeId.isNotEmpty) {
      for (final session in sessions) {
        if (session.nativeSessionId.trim() == normalizedNativeId) {
          return session.id;
        }
      }
    }
    return normalizedId;
  }

  Future<void> _refreshSelectedModelCatalogs() {
    final projection = _projection.current.adaptiveFlywheel;
    final agentIds = <String>{
      for (final assignment in projection.inspection?.assignments ?? const [])
        if (assignment.agentId.trim().isNotEmpty) assignment.agentId.trim(),
      if (projection.assistant.agentId.trim().isNotEmpty)
        projection.assistant.agentId.trim(),
    };
    return _controller.refreshAgentModelCatalogs(agentIds);
  }

  Future<bool> _saveActorBindings(
    List<AdaptiveFlywheelAssignmentIntent> assignments, {
    required TraceContext? trace,
    bool emitCompletion = true,
  }) async {
    final bySlot = <String, List<AdaptiveFlywheelBinding>>{};
    for (final assignment in assignments) {
      final slotId = assignment.slotId.trim();
      final agentId = assignment.agentId.trim();
      if (slotId.isEmpty || agentId.isEmpty) continue;
      bySlot
          .putIfAbsent(slotId, () => <AdaptiveFlywheelBinding>[])
          .add(
            AdaptiveFlywheelBinding(
              slotId: slotId,
              ordinal: assignment.ordinal,
              valueId: agentId,
              model: assignment.modelId.trim(),
              reasoningEffort: assignment.reasoningEffort.trim(),
            ),
          );
    }
    for (final values in bySlot.values) {
      values.sort((left, right) => left.ordinal.compareTo(right.ordinal));
    }
    await _adaptiveFlywheel.saveActorBindings(bySlot);
    if (_adaptiveFlywheel.error.isNotEmpty) return false;
    if (emitCompletion) {
      effects.add(AdaptiveFlywheelSaveCompleted(trace: trace));
    }
    return true;
  }

  Future<void> _loadAssistantProfile({TraceContext? trace}) async {
    final conversation =
        _controller.clientConversationController.selectedConversation;
    if (conversation == null || !conversation.group) {
      _clearAssistantProfile();
      _projection.setAssistantProfile(
        const AdaptiveFlywheelAssistantProjection.empty(),
        trace: trace,
      );
      return;
    }
    final membership =
        conversation.assistantMembership ??
        (conversation.activeAgentMemberships.isEmpty
            ? null
            : conversation.activeAgentMemberships.first);
    final agentId = membership?.principal.agentId.trim().isNotEmpty == true
        ? membership!.principal.agentId.trim()
        : (_projection
                  .current
                  .adaptiveFlywheel
                  .callableAgents
                  .firstOrNull
                  ?.id ??
              '');
    final defaults = _assistantDefaults(agentId);
    _projection.setAssistantProfile(
      AdaptiveFlywheelAssistantProjection(
        conversationId: conversation.id,
        membershipId: membership?.id ?? '',
        agentId: agentId,
        modelId: defaults.modelId,
        reasoningEffort: defaults.reasoningEffort,
        profileRevision: 0,
        loading: membership != null,
        saving: false,
      ),
      trace: trace,
    );
    if (membership == null) {
      _clearAssistantProfile();
      return;
    }
    final profile = await _controller.clientConversationController
        .membershipProfile(membership.id);
    final selected =
        _controller.clientConversationController.selectedConversation;
    if (selected == null || selected.id != conversation.id || !selected.group) {
      return;
    }
    _assistantProfile = profile == null
        ? null
        : Map<String, dynamic>.unmodifiable(profile);
    _assistantProfileConversationId = conversation.id;
    _assistantProfileMembershipId = membership.id;
    final modelId = (profile?['preferredModel'] ?? '').toString().trim();
    final effort = (profile?['preferredReasoningEffort'] ?? '')
        .toString()
        .trim();
    final resolved = _assistantDefaults(
      agentId,
      modelId: modelId,
      reasoningEffort: effort,
    );
    _projection.setAssistantProfile(
      AdaptiveFlywheelAssistantProjection(
        conversationId: conversation.id,
        membershipId: membership.id,
        agentId: agentId,
        modelId: resolved.modelId,
        reasoningEffort: resolved.reasoningEffort,
        profileRevision: (profile?['revision'] as num?)?.toInt() ?? 0,
        loading: false,
        saving: false,
      ),
      trace: trace,
    );
  }

  ({String modelId, String reasoningEffort}) _assistantDefaults(
    String agentId, {
    String modelId = '',
    String reasoningEffort = '',
  }) {
    final agent = _projection.callableAgent(agentId);
    final selectedModel = modelId.trim().isNotEmpty
        ? modelId.trim()
        : (agent?.models.firstOrNull?.id ?? '');
    final model = agent?.model(selectedModel);
    return (
      modelId: selectedModel,
      reasoningEffort: reasoningEffort.trim().isNotEmpty
          ? reasoningEffort.trim()
          : (model?.defaultReasoningEffort ?? ''),
    );
  }

  Future<bool> _updateAssistantProfile({
    required String agentId,
    required String modelId,
    required String reasoningEffort,
    TraceContext? trace,
    bool emitCompletion = true,
  }) async {
    final normalizedAgentId = agentId.trim();
    final controller = _controller.clientConversationController;
    final conversation = controller.selectedConversation;
    if (conversation == null ||
        !conversation.group ||
        normalizedAgentId.isEmpty) {
      effects.add(
        AdaptiveFlywheelActionRejected(
          'adaptive_flywheel_assistant_required',
          trace: trace,
        ),
      );
      return false;
    }
    _projection.setAssistantProfile(
      _projection.current.adaptiveFlywheel.assistant.copyWith(saving: true),
      trace: trace,
    );
    var membership = _membershipForAgent(conversation, normalizedAgentId);
    if (membership == null) {
      final agent = _projection.callableAgent(normalizedAgentId);
      final joined = await controller.ensureSelectedAgentMembership(
        agentId: normalizedAgentId,
        displayName: agent?.displayName ?? normalizedAgentId,
      );
      if (!joined) {
        _rejectProfileUpdate('adaptive_flywheel_membership_unavailable', trace);
        return false;
      }
      final refreshed = controller.selectedConversation;
      if (refreshed == null || refreshed.id != conversation.id) {
        _rejectProfileUpdate('adaptive_flywheel_conversation_changed', trace);
        return false;
      }
      membership = _membershipForAgent(refreshed, normalizedAgentId);
    }
    if (membership == null ||
        !await controller.setSelectedAssistantMembership(membership.id)) {
      _rejectProfileUpdate('adaptive_flywheel_assistant_unavailable', trace);
      return false;
    }
    var profile =
        _assistantProfileConversationId == conversation.id &&
            _assistantProfileMembershipId == membership.id
        ? _assistantProfile
        : null;
    profile ??= await controller.membershipProfile(membership.id);
    if (profile == null) {
      _rejectProfileUpdate('adaptive_flywheel_profile_unavailable', trace);
      return false;
    }
    await controller.updateMembershipProfileIntent(
      membershipId: membership.id,
      expectedRevision: (profile['revision'] as num?)?.toInt() ?? 0,
      intent: {
        'requiredCapabilities': _profileStringList(
          profile['requiredCapabilities'],
        ),
        'preferredCapabilities': _profileStringList(
          profile['preferredCapabilities'],
        ),
        'skillReferences': _profileStringList(profile['skillReferences']),
        'preferredModel': modelId.trim().isEmpty ? null : modelId.trim(),
        'preferredReasoningEffort': reasoningEffort.trim().isEmpty
            ? null
            : reasoningEffort.trim(),
        'preferredEnvironment': profile['preferredEnvironment'],
      },
    );
    await _loadAssistantProfile(trace: trace);
    if (emitCompletion) {
      effects.add(AdaptiveFlywheelSaveCompleted(trace: trace));
    }
    return true;
  }

  void _rejectProfileUpdate(String reasonCode, TraceContext? trace) {
    _projection.setAssistantProfile(
      _projection.current.adaptiveFlywheel.assistant.copyWith(saving: false),
      trace: trace,
    );
    effects.add(AdaptiveFlywheelActionRejected(reasonCode, trace: trace));
  }

  ClientConversationMembership? _membershipForAgent(
    ClientConversation conversation,
    String agentId,
  ) {
    for (final membership in conversation.activeAgentMemberships) {
      if (membership.principal.agentId == agentId) return membership;
    }
    return null;
  }

  List<String> _profileStringList(Object? value) => value is List
      ? value
            .map((entry) => entry.toString().trim())
            .where((entry) => entry.isNotEmpty)
            .toList(growable: false)
      : const [];

  void _clearAssistantProfile() {
    _assistantProfile = null;
    _assistantProfileConversationId = '';
    _assistantProfileMembershipId = '';
  }

  void _run(
    Future<void> Function() action,
    TraceContext? trace, {
    String reasonCode = 'agents_action_failed',
  }) {
    unawaited(
      Future<void>.microtask(action).catchError((Object _) {
        effects.add(
          reasonCode == 'agents_action_failed'
              ? AgentSelectionRejected(reasonCode, trace: trace)
              : AdaptiveFlywheelActionRejected(reasonCode, trace: trace),
        );
      }),
    );
  }
}
