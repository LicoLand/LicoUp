import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_runtime/presentation_runtime.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/features/agents/acativa/acativa_controller.dart';
import 'package:licoup/src/composition/renderer_intent_trace.dart';
import 'package:licoup/src/contracts/acativa_models.dart';
import 'package:licoup/src/contracts/agent_conversation_session.dart';
import 'package:licoup/src/frontend/features/agents/ui/conversation_session_ordering.dart';
import 'package:licoup/src/contracts/client_conversation_models.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/presentation/agents/agents_binding.dart';
import 'package:licoup/src/presentation/agents/agents_effect.dart';
import 'package:licoup/src/presentation/agents/agents_intent.dart';
import 'package:licoup/src/presentation/agents/acativa_projection.dart';
import 'package:licoup/src/presentation/agents/agents_projection.dart';
import 'package:licoup/src/presentation/agents/agents_view.dart';
import 'package:licoup/src/projections/agents/agents_presentation_source.dart';
import 'package:licoup/src/projections/agents/agents_projection_producer.dart';
import 'package:licoup/src/projections/close_broadcast_controller.dart';

final class AgentsFeatureComposition {
  AgentsFeatureComposition(
    ClientController controller, {
    RendererIntentTraceFactory? beginRendererIntent,
  }) {
    _acativa = AcativaController(gateway: controller.acativaGateway);
    _effects = _AgentsEffects();
    _projection = AgentsProjectionProducer(controller, acativa: _acativa);
    _intents = _AgentsIntents.pending(
      controller,
      beginRendererIntent: beginRendererIntent,
    );
    _intents.attach(acativa: _acativa, projection: _projection);
    _intents.effects = _effects;
    _catalogSource = AgentsPresentationSource(projection: _projection);
    catalogEntry = presentationProviderEntry(_catalogSource);
    catalogActions = AgentsCatalogActions.fromIntents(_intents);
    binding = AgentsBinding(
      projection: _projection,
      intents: _intents,
      effects: _effects,
    );
  }

  late final AcativaController _acativa;
  late final AgentsProjectionProducer _projection;
  late final _AgentsEffects _effects;
  late final _AgentsIntents _intents;
  late final AgentsPresentationSource _catalogSource;

  /// F01 Riverpod entry for the agent catalog resource.
  late final PresentationProviderEntry<AgentsProjection> catalogEntry;

  /// Narrow renderer actions with the agents scope pinned.
  late final AgentsCatalogActions catalogActions;
  late final AgentsBinding binding;
  bool _closed = false;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _catalogSource.dispose();
    await _projection.close();
    _acativa.dispose();
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
  late AcativaController _acativa;
  late AgentsProjectionProducer _projection;
  late _AgentsEffects effects;
  Map<String, dynamic>? _assistantProfile;
  String _assistantProfileConversationId = '';
  String _assistantProfileMembershipId = '';

  void attach({
    required AcativaController acativa,
    required AgentsProjectionProducer projection,
  }) {
    _acativa = acativa;
    _projection = projection;
  }

  @override
  void send(AgentsIntent intent) {
    final trace = resolveRendererIntentTrace(
      intent.trace,
      _beginRendererIntent,
    );
    switch (intent) {
      case InitializeAcativa(:final initialRevision):
        _run(
          () async {
            await Future.wait([
              _acativa.initialize(),
              _loadAssistantProfile(trace: trace),
            ]);
            if (initialRevision.isNotEmpty &&
                _acativa.definitions.any(
                  (definition) => definition.revisionDigest == initialRevision,
                ) &&
                _acativa.selectedRevision != initialRevision) {
              await _acativa.selectDefinition(initialRevision);
            }
            await _refreshSelectedModelCatalogs();
          },
          trace,
          reasonCode: 'acativa_initialize_failed',
        );
      case ImportAcativaPackage(:final path):
        if (path.trim().isEmpty) {
          effects.add(
            AcativaActionRejected('acativa_package_required', trace: trace),
          );
          return;
        }
        final conversation =
            _controller.clientConversationController.selectedConversation;
        final conversationId = conversation != null && conversation.group
            ? conversation.id
            : '';
        _run(
          () => _acativa.importPackage(
            path.trim(),
            conversationId: conversationId,
          ),
          trace,
          reasonCode: 'acativa_import_failed',
        );
      case SelectAcativaDefinition(:final revision):
        if (revision.trim().isEmpty) return;
        _run(
          () => _acativa.selectDefinition(revision.trim()),
          trace,
          reasonCode: 'acativa_selection_failed',
        );
      case SaveAcativaActorBindings(:final assignments):
        _run(
          () async {
            await _saveActorBindings(assignments, trace: trace);
          },
          trace,
          reasonCode: 'acativa_bindings_save_failed',
        );
      case RefreshAcativaModelCatalogs(:final agentIds):
        _run(
          () => _controller.refreshAgentModelCatalogs(
            agentIds
                .map((id) => id.trim())
                .where((id) => id.isNotEmpty)
                .toSet(),
          ),
          trace,
          reasonCode: 'acativa_model_refresh_failed',
        );
      case ReadAcativaAssistantProfile():
        _run(
          () => _loadAssistantProfile(trace: trace),
          trace,
          reasonCode: 'acativa_profile_read_failed',
        );
      case UpdateAcativaAssistantProfile(
        :final agentId,
        :final modelId,
        :final reasoningEffort,
        :final permissionMode,
      ):
        _run(
          () async {
            await _updateAssistantProfile(
              agentId: agentId,
              modelId: modelId,
              reasoningEffort: reasoningEffort,
              permissionMode: permissionMode,
              trace: trace,
            );
          },
          trace,
          reasonCode: 'acativa_profile_update_failed',
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
        _controller.selectGroupConversationSession(
          groupConversationId,
          agentId,
          nativeSessionId.isNotEmpty ? nativeSessionId : sessionId,
        );
      case StartAgentConversation(:final agentId):
        _run(() async {
          _controller.clientConversationController.clearSelection();
          await _controller.selectConversationAgent(agentId);
          _controller.startNewConversationSession();
        }, trace);
      case OpenAgentConversation(:final agentId):
        _run(() async {
          _controller.clientConversationController.clearSelection();
          await _controller.selectConversationAgent(agentId);
          if (!_controller.conversationSessionsByAgent.containsKey(agentId)) {
            await _controller.loadConversationSessions(agentId);
          }
          AgentConversationSession? latest;
          for (final session
              in _controller.conversationSessionsByAgent[agentId] ??
                  const <AgentConversationSession>[]) {
            // Sub-agent threads merge into their parent conversation and are
            // never themselves the Agent's latest row.
            if (session.parentSessionId.trim().isNotEmpty) continue;
            if (latest == null ||
                conversationSessionSortTime(session) >
                    conversationSessionSortTime(latest)) {
              latest = session;
            }
          }
          if (latest == null) {
            _controller.startNewConversationSession();
          } else {
            _controller.selectConversationSession(latest.id);
          }
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
    final projection = _projection.current.acativa;
    final agentIds = <String>{
      for (final assignment in projection.inspection?.assignments ?? const [])
        if (assignment.agentId.trim().isNotEmpty) assignment.agentId.trim(),
      if (projection.assistant.agentId.trim().isNotEmpty)
        projection.assistant.agentId.trim(),
    };
    return _controller.refreshAgentModelCatalogs(agentIds);
  }

  Future<bool> _saveActorBindings(
    List<AcativaAssignmentIntent> assignments, {
    required TraceContext? trace,
    bool emitCompletion = true,
  }) async {
    final bySlot = <String, List<AcativaBinding>>{};
    for (final assignment in assignments) {
      final slotId = assignment.slotId.trim();
      final agentId = assignment.agentId.trim();
      if (slotId.isEmpty || agentId.isEmpty) continue;
      bySlot
          .putIfAbsent(slotId, () => <AcativaBinding>[])
          .add(
            AcativaBinding(
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
    await _acativa.saveActorBindings(bySlot);
    if (_acativa.error.isNotEmpty) return false;
    if (emitCompletion) {
      effects.add(AcativaSaveCompleted(trace: trace));
    }
    return true;
  }

  Future<void> _loadAssistantProfile({TraceContext? trace}) async {
    final conversation =
        _controller.clientConversationController.selectedConversation;
    if (conversation == null || !conversation.group) {
      _clearAssistantProfile();
      _projection.setAssistantProfile(
        const AcativaAssistantProjection.empty(),
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
        : (_projection.current.acativa.callableAgents.firstOrNull?.id ?? '');
    final defaults = _assistantDefaults(agentId);
    _projection.setAssistantProfile(
      AcativaAssistantProjection(
        conversationId: conversation.id,
        membershipId: membership?.id ?? '',
        agentId: agentId,
        modelId: defaults.modelId,
        reasoningEffort: defaults.reasoningEffort,
        permissionMode: '',
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
    final permissionMode = _assistantPermissionMode(
      agentId,
      (profile?['preferredPermissionMode'] ?? '').toString(),
    );
    _projection.setAssistantProfile(
      AcativaAssistantProjection(
        conversationId: conversation.id,
        membershipId: membership.id,
        agentId: agentId,
        modelId: resolved.modelId,
        reasoningEffort: resolved.reasoningEffort,
        permissionMode: permissionMode,
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

  /// Resolve the persisted permission mode against the agent's executable
  /// modes: an unsupported stored value falls back to empty rather than being
  /// displayed or re-persisted as applied.
  String _assistantPermissionMode(String agentId, String stored) {
    final modes = _projection.callableAgent(agentId)?.permissionModes;
    if (modes == null || modes.isEmpty) {
      return '';
    }
    final trimmed = stored.trim();
    if (trimmed.isEmpty) {
      return modes.first;
    }
    return modes.contains(trimmed) ? trimmed : '';
  }

  Future<bool> _updateAssistantProfile({
    required String agentId,
    required String modelId,
    required String reasoningEffort,
    String? permissionMode,
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
        AcativaActionRejected('acativa_assistant_required', trace: trace),
      );
      return false;
    }
    _projection.setAssistantProfile(
      _projection.current.acativa.assistant.copyWith(saving: true),
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
        _rejectProfileUpdate('acativa_membership_unavailable', trace);
        return false;
      }
      final refreshed = controller.selectedConversation;
      if (refreshed == null || refreshed.id != conversation.id) {
        _rejectProfileUpdate('acativa_conversation_changed', trace);
        return false;
      }
      membership = _membershipForAgent(refreshed, normalizedAgentId);
    }
    if (membership == null ||
        !await controller.setSelectedAssistantMembership(membership.id)) {
      _rejectProfileUpdate('acativa_assistant_unavailable', trace);
      return false;
    }
    var profile =
        _assistantProfileConversationId == conversation.id &&
            _assistantProfileMembershipId == membership.id
        ? _assistantProfile
        : null;
    profile ??= await controller.membershipProfile(membership.id);
    if (profile == null) {
      _rejectProfileUpdate('acativa_profile_unavailable', trace);
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
        'preferredPermissionMode': _persistedPermissionMode(
          agentId: normalizedAgentId,
          requested: permissionMode,
          profile: profile,
        ),
      },
    );
    await _loadAssistantProfile(trace: trace);
    if (emitCompletion) {
      effects.add(AcativaSaveCompleted(trace: trace));
    }
    return true;
  }

  /// Persist only a mode the agent's adapter can actually execute: an
  /// explicit supported selection wins, an omitted update preserves the
  /// stored value when still valid, and anything else clears the field so an
  /// unsupported mode is never re-persisted as applied.
  String? _persistedPermissionMode({
    required String agentId,
    required String? requested,
    required Map<String, dynamic> profile,
  }) {
    final modes = _projection.callableAgent(agentId)?.permissionModes;
    if (modes == null || modes.isEmpty) {
      return null;
    }
    final candidate =
        (requested ?? (profile['preferredPermissionMode'] ?? '').toString())
            .trim();
    if (candidate.isEmpty) {
      return null;
    }
    return modes.contains(candidate) ? candidate : null;
  }

  void _rejectProfileUpdate(String reasonCode, TraceContext? trace) {
    _projection.setAssistantProfile(
      _projection.current.acativa.assistant.copyWith(saving: false),
      trace: trace,
    );
    effects.add(AcativaActionRejected(reasonCode, trace: trace));
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
              : AcativaActionRejected(reasonCode, trace: trace),
        );
      }),
    );
  }
}
