import 'dart:async';

import 'package:licoup/src/application/features/agents/conversation/conversation_working_directory_fallback.dart';
import 'package:licoup/src/application/features/agents/policy/conversation_session_index.dart';
import 'package:licoup/src/application/features/agents/workspace/agent_workspace_coordinator.dart';
import 'package:licoup/src/platform/agents/agent_conversation_projection_store.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/agent_conversation_context_projection.dart';

const int conversationSessionPageSize = 50;
const List<int> conversationInitialProgressiveMilestones = [3, 10, 20];
const String conversationCatalogRefreshKey = '__lico_catalog_refresh__';
const int mobileConversationSessionLimit = 20;
const String mobileConversationSessionLoadFailedSelectionId =
    '__mobile_native_session_unresolved__';
const String conversationSessionReadbackPendingSelectionId =
    '__lico_native_session_readback_pending__';
const String conversationSessionLoadFailedSelectionId =
    '__lico_native_session_load_failed__';

final class ConversationSessionPage {
  const ConversationSessionPage({
    required this.sessions,
    required this.hasMore,
  });

  final List<AgentConversationSession> sessions;
  final bool hasMore;
}

typedef ConversationSessionProgressCallback =
    void Function(ConversationSessionPage page);

/// Owns deterministic session-list reconciliation and native identity binding.
mixin AgentConversationSessionStateController on AgentWorkspaceCoordinator {
  Future<void> _conversationProjectionPersistenceTail = Future<void>.value();

  bool conversationCommitCatalog(
    String agentId,
    ConversationSessionPage page, {
    required bool replaceAll,
    required bool updateStatus,
    bool notifyChanges = true,
    bool clearLiveProjectionFromProviderReadback = true,
  }) {
    final previous = conversationSessionsByAgent[agentId] ?? const [];
    final previousSelected = selectedConversationAgentId == agentId
        ? selectedConversationSession
        : null;
    var next = replaceAll || !page.hasMore
        ? page.sessions
        : conversationReconcileSessionHead(previous, page.sessions);
    final durable = durableConversationProjectionsByAgent[agentId] ?? const [];
    if (durable.isNotEmpty) {
      next = mergeConversationSessionsByUpdatedAt(durable, next);
      next = _conversationPreserveSummarizedTitles(durable, next);
    }
    next = _conversationPreserveBoundWorkingDirectories(previous, next);
    // Native catalog cwd wins over a locally baked agent-workspace path when
    // a newer turn-bound projection otherwise shadows the project directory.
    next = _conversationRecoverUsableWorkingDirectories(page.sessions, next);
    _conversationPromoteNativeTitles(agentId, page.sessions, next);
    final liveProjection = liveConversationMessagesByAgent[agentId] ?? const [];
    AgentConversationSession? providerReadback;
    if (previousSelected != null && liveProjection.isNotEmpty) {
      // A completed streamed turn is already an authoritative local session.
      // Provider history can expose the same session identity before its
      // messages catch up, so identity alone cannot authorize replacement.
      // Retain the turn-bound projection until provider readback covers the
      // exact live user/assistant messages.
      final matchingIndex = next.indexWhere(
        (session) =>
            session.nativeSessionId.trim() ==
            previousSelected.nativeSessionId.trim(),
      );
      if (matchingIndex >= 0) {
        providerReadback = next[matchingIndex];
      }
      if (matchingIndex < 0) {
        next = insertConversationSessionByUpdatedAt(next, previousSelected);
      } else if (!_sessionCoversMessages(next[matchingIndex], liveProjection)) {
        // Keep the catalog project directory on the retained turn projection.
        // Replacing the whole session used to drop workingDirectory and force
        // the composer back onto the client-owned agent-workspace fallback.
        var retainedSession = previousSelected;
        final catalogDirectory = next[matchingIndex].workingDirectory;
        if (!isUsableLocalConversationWorkingDirectory(
              retainedSession.workingDirectory,
            ) &&
            isUsableLocalConversationWorkingDirectory(catalogDirectory)) {
          retainedSession = retainedSession.withWorkingDirectory(
            catalogDirectory,
          );
        }
        final retained = List<AgentConversationSession>.from(next);
        retained[matchingIndex] = retainedSession;
        next = List<AgentConversationSession>.unmodifiable(retained);
      }
    }
    // Live retention can reintroduce an empty cwd; recover again from the
    // native page so the composer bind path stays aligned with catalog facts.
    next = _conversationRecoverUsableWorkingDirectories(page.sessions, next);
    final sessionsChanged = !conversationSessionListsEquivalent(previous, next);
    final hasMoreChanged =
        (conversationSessionsHasMoreByAgent[agentId] ?? false) != page.hasMore;
    if (sessionsChanged) {
      conversationSessionsByAgent = {
        ...conversationSessionsByAgent,
        agentId: next,
      };
    }
    if (hasMoreChanged) {
      conversationSessionsHasMoreByAgent = {
        ...conversationSessionsHasMoreByAgent,
        agentId: page.hasMore,
      };
    }

    if (selectedConversationAgentId == agentId) {
      conversationReconcileSelectedSession(agentId, next, previous: previous);
      if (clearLiveProjectionFromProviderReadback) {
        conversationClearLiveProjectionWhenReadBack(
          agentId,
          providerReadback: providerReadback,
        );
      }
      final activeChanged = !conversationSessionsEquivalent(
        previousSelected,
        selectedConversationSession,
      );
      if (notifyChanges && (sessionsChanged || hasMoreChanged)) {
        if (hasMoreChanged ||
            _conversationCatalogStructureChanged(previous, next)) {
          agentWorkspaceNotifyConversationStructureChanged(
            activeChanged: activeChanged,
          );
        } else if (activeChanged) {
          agentWorkspaceNotifyActiveConversationChanged();
        }
      }
      if (updateStatus) {
        agentWorkspaceSetLocalizedStatusMessage(
          next.isEmpty
              ? '$agentId 暂未发现原生历史。'
              : page.hasMore
              ? '已读取 ${next.length} 条 $agentId 原生历史，滚动到底继续加载。'
              : '已读取 ${next.length} 条 $agentId 原生历史。',
          next.isEmpty
              ? 'No native $agentId history found.'
              : page.hasMore
              ? 'Read ${next.length} native $agentId ${next.length == 1 ? 'session' : 'sessions'}. Scroll to the bottom to load more.'
              : 'Read ${next.length} native $agentId ${next.length == 1 ? 'session' : 'sessions'}.',
        );
        statusCaption = 'Agent chat';
      }
    }
    return sessionsChanged;
  }

  @override
  @override
  Future<void> loadConversationToolAllowlists() async {
    try {
      const store = AgentToolAllowlistStore();
      final restored = await store.load(agentWorkspacePortableData);
      replaceConversationToolAllowlists(restored);
    } on Object {
      // A damaged allowlist file must not block the client.
    }
  }

  Future<void> hydrateConversationProjectionCache() async {
    Map<String, List<AgentConversationSession>> restored;
    try {
      restored = await agentConversationProjectionRepository.load(
        agentWorkspacePortableData,
      );
    } on Object {
      return;
    }
    // Drop client-owned fallback paths from durable cache. They are not the
    // conversation's project directory and otherwise shadow native history cwd
    // after relaunch until the user manually reselects the agent.
    final cleaned = <String, List<AgentConversationSession>>{
      for (final entry in restored.entries)
        entry.key: List<AgentConversationSession>.unmodifiable([
          for (final session in entry.value)
            if (isUsableLocalConversationWorkingDirectory(
              session.workingDirectory,
            ))
              session
            else
              session.withWorkingDirectory(''),
        ]),
    };
    durableConversationProjectionsByAgent =
        Map<String, List<AgentConversationSession>>.unmodifiable(cleaned);
    if (cleaned.isEmpty) return;

    conversationSessionsByAgent =
        Map<String, List<AgentConversationSession>>.unmodifiable({
          ...conversationSessionsByAgent,
          for (final entry in cleaned.entries)
            entry.key: mergeConversationSessionsByUpdatedAt(
              entry.value,
              conversationSessionsByAgent[entry.key] ??
                  const <AgentConversationSession>[],
            ),
        });
  }

  Future<bool> _conversationPersistProjection(
    AgentConversationSession session,
  ) async {
    final agentId = session.agentId.trim();
    if (agentId.isEmpty) return false;
    final existing =
        durableConversationProjectionsByAgent[agentId] ??
        const <AgentConversationSession>[];
    final next = insertConversationSessionByUpdatedAt(
      existing,
      session,
    ).take(100).toList(growable: false);
    durableConversationProjectionsByAgent =
        Map<String, List<AgentConversationSession>>.unmodifiable({
          ...durableConversationProjectionsByAgent,
          agentId: List<AgentConversationSession>.unmodifiable(next),
        });
    return _conversationScheduleProjectionSave();
  }

  void _conversationPromoteNativeTitles(
    String agentId,
    List<AgentConversationSession> nativeSessions,
    List<AgentConversationSession> reconciled,
  ) {
    final durable =
        durableConversationProjectionsByAgent[agentId] ??
        const <AgentConversationSession>[];
    if (durable.isEmpty || nativeSessions.isEmpty) return;

    final durableByIdentity = <String, AgentConversationSession>{
      for (final session in durable)
        _conversationSessionIdentity(session): session,
    };
    final reconciledByIdentity = <String, AgentConversationSession>{
      for (final session in reconciled)
        _conversationSessionIdentity(session): session,
    };
    var promoted = durable;
    var changed = false;
    for (final nativeSession in nativeSessions) {
      final identity = _conversationSessionIdentity(nativeSession);
      final previous = durableByIdentity[identity];
      final accepted = reconciledByIdentity[identity];
      if (previous == null ||
          accepted == null ||
          accepted.title.trim().isEmpty ||
          accepted.title.trim() == previous.title.trim()) {
        continue;
      }
      promoted = insertConversationSessionByUpdatedAt(
        promoted,
        accepted,
      ).take(100).toList(growable: false);
      changed = true;
    }
    if (!changed) return;
    durableConversationProjectionsByAgent =
        Map<String, List<AgentConversationSession>>.unmodifiable({
          ...durableConversationProjectionsByAgent,
          agentId: List<AgentConversationSession>.unmodifiable(promoted),
        });
    unawaited(_conversationScheduleProjectionSave());
  }

  List<AgentConversationSession> _conversationPreserveSummarizedTitles(
    List<AgentConversationSession> durable,
    List<AgentConversationSession> incoming,
  ) {
    final durableByIdentity = <String, AgentConversationSession>{
      for (final session in durable)
        _conversationSessionIdentity(session): session,
    };
    var changed = false;
    final preserved = incoming
        .map((session) {
          final previous =
              durableByIdentity[_conversationSessionIdentity(session)];
          if (previous == null ||
              previous.title.trim() == session.title.trim()) {
            return session;
          }
          final firstUserFallback = visibleAgentConversationTitle(
            '',
            session.messages,
          );
          if (session.title.trim() != firstUserFallback.trim()) {
            return session;
          }
          changed = true;
          return session.withTitle(previous.title);
        })
        .toList(growable: false);
    return changed
        ? List<AgentConversationSession>.unmodifiable(preserved)
        : incoming;
  }

  String _conversationSessionIdentity(AgentConversationSession session) {
    final nativeId = session.nativeSessionId.trim();
    return nativeId.isNotEmpty ? nativeId : session.id.trim();
  }

  Future<bool> _conversationScheduleProjectionSave() {
    if (!initialized) return Future<bool>.value(true);
    final snapshot = durableConversationProjectionsByAgent;
    final save = _conversationProjectionPersistenceTail.then((_) async {
      try {
        await agentConversationProjectionRepository.save(
          agentWorkspacePortableData,
          snapshot,
        );
        return true;
      } on Object {
        return false;
      }
    });
    _conversationProjectionPersistenceTail = save.then<void>((_) {});
    return save;
  }

  Future<void> conversationFlushProjectionPersistence() {
    return _conversationProjectionPersistenceTail;
  }

  List<AgentConversationSession> _conversationPreserveBoundWorkingDirectories(
    List<AgentConversationSession> previous,
    List<AgentConversationSession> incoming,
  ) {
    if (previous.isEmpty || incoming.isEmpty) return incoming;

    final byNativeSessionId = <String, String>{};
    final bySessionId = <String, String>{};
    for (final session in previous) {
      final workingDirectory = session.workingDirectory.trim();
      // Never bind the client-owned fallback or a personal-tree root onto a
      // later native readback — those are not the conversation's project path.
      if (!isUsableLocalConversationWorkingDirectory(workingDirectory)) {
        continue;
      }

      final nativeSessionId = session.nativeSessionId.trim();
      if (nativeSessionId.isNotEmpty) {
        byNativeSessionId[nativeSessionId] = workingDirectory;
      }
      final sessionId = session.id.trim();
      if (sessionId.isNotEmpty) {
        bySessionId[sessionId] = workingDirectory;
      }
    }
    if (byNativeSessionId.isEmpty && bySessionId.isEmpty) return incoming;

    var changed = false;
    final merged = incoming
        .map((session) {
          final incomingDirectory = session.workingDirectory.trim();
          if (isUsableLocalConversationWorkingDirectory(incomingDirectory)) {
            return session;
          }
          final nativeSessionId = session.nativeSessionId.trim();
          final workingDirectory =
              (nativeSessionId.isEmpty
                  ? null
                  : byNativeSessionId[nativeSessionId]) ??
              bySessionId[session.id.trim()] ??
              '';
          if (!isUsableLocalConversationWorkingDirectory(workingDirectory)) {
            return session;
          }
          changed = true;
          return session.withWorkingDirectory(workingDirectory);
        })
        .toList(growable: false);
    return changed
        ? List<AgentConversationSession>.unmodifiable(merged)
        : incoming;
  }

  bool _conversationCatalogStructureChanged(
    List<AgentConversationSession> previous,
    List<AgentConversationSession> next,
  ) {
    if (previous.length != next.length) return true;
    for (var index = 0; index < previous.length; index += 1) {
      if (previous[index].id != next[index].id) return true;
    }
    return false;
  }

  void conversationReconcileSelectedSession(
    String agentId,
    List<AgentConversationSession> sessions, {
    List<AgentConversationSession> previous = const [],
  }) {
    final pendingNativeSessionId = conversationPendingNativeSessionId(agentId);
    if (pendingNativeSessionId.isNotEmpty) {
      final matches = sessions
          .where(
            (session) =>
                session.nativeSessionId.trim() == pendingNativeSessionId,
          )
          .toList(growable: false);
      if (matches.length == 1) {
        conversationClearNativeSessionPending(agentId);
        selectedConversationSessionId = matches.single.id;
        if (lastError == 'native_session_readback_missing') {
          lastError = '';
        }
      } else {
        selectedConversationSessionId =
            conversationSessionReadbackPendingSelectionId;
      }
      return;
    }
    if (preparingNewConversation) {
      return;
    }
    if (sessions.isEmpty) {
      selectedConversationSessionId = '';
      return;
    }
    final selectedId = selectedConversationSessionId.trim();
    if (selectedId.isEmpty) {
      selectedConversationSessionId = sessions.first.id;
      return;
    }
    if (sessions.any((session) => session.id == selectedId)) {
      return;
    }
    final nativeMatches = sessions
        .where((session) => session.nativeSessionId.trim() == selectedId)
        .toList(growable: false);
    if (nativeMatches.length == 1) {
      selectedConversationSessionId = nativeMatches.single.id;
      return;
    }
    // Provider readback and native-id dedup can re-emit the same composer or
    // CLI session under a fresh projection id. Rebind through the stable native
    // identity instead of leaving the UI on an orphaned projection id.
    final nativeIdentity = _conversationNativeIdentityForProjectionId(
      agentId,
      selectedId,
      previous: previous,
    );
    if (nativeIdentity.isEmpty) {
      return;
    }
    final rebound = sessions
        .where((session) => session.nativeSessionId.trim() == nativeIdentity)
        .toList(growable: false);
    if (rebound.length == 1) {
      selectedConversationSessionId = rebound.single.id;
    }
  }

  String _conversationNativeIdentityForProjectionId(
    String agentId,
    String projectionId, {
    required List<AgentConversationSession> previous,
  }) {
    for (final session in previous) {
      if (session.id == projectionId) {
        return session.nativeSessionId.trim();
      }
    }
    for (final session
        in durableConversationProjectionsByAgent[agentId] ?? const []) {
      if (session.id == projectionId) {
        return session.nativeSessionId.trim();
      }
    }
    return '';
  }

  List<AgentConversationSession> conversationReconcileSessionHead(
    List<AgentConversationSession> previous,
    List<AgentConversationSession> refreshedHead,
  ) {
    if (previous.length <= conversationSessionPageSize) {
      return refreshedHead;
    }
    final refreshedIds = refreshedHead.map((session) => session.id).toSet();
    final retainedTail = previous
        .skip(conversationSessionPageSize)
        .where((session) => !refreshedIds.contains(session.id));
    return sortConversationSessionsByUpdatedAt([
      ...refreshedHead,
      ...retainedTail,
    ]);
  }

  String conversationPendingNativeSessionId(String agentId) {
    return (pendingConversationNativeSessionIds[agentId] ?? '').trim();
  }

  void conversationMarkNativeSessionPending(
    String agentId,
    String nativeSessionId,
  ) {
    pendingConversationNativeSessionIds = {
      ...pendingConversationNativeSessionIds,
      agentId: nativeSessionId.trim(),
    };
    setSelectedConversationSessionId(
      agentId,
      conversationSessionReadbackPendingSelectionId,
    );
  }

  void conversationClearNativeSessionPending(String agentId) {
    if (!pendingConversationNativeSessionIds.containsKey(agentId)) {
      return;
    }
    pendingConversationNativeSessionIds = {
      ...pendingConversationNativeSessionIds,
    }..remove(agentId);
  }

  /// Keeps a completed streamed turn visible until the native history source
  /// contains the same user/assistant messages. Some adapters persist their
  /// transcript shortly after the transport reports completion; clearing the
  /// live projection before that readback converges makes the reply flash and
  /// then disappear.
  void conversationClearLiveProjectionWhenReadBack(
    String agentId, {
    required AgentConversationSession? providerReadback,
  }) {
    final live = liveConversationMessagesByAgent[agentId] ?? const [];
    if (live.isEmpty) {
      return;
    }
    if (providerReadback == null) {
      return;
    }
    if (!_sessionCoversMessages(providerReadback, live)) {
      return;
    }
    liveConversationMessagesByAgent = {
      for (final entry in liveConversationMessagesByAgent.entries)
        if (entry.key != agentId) entry.key: entry.value,
    };
  }

  bool _conversationMessageParticipatesInReadback(
    AgentConversationMessage message,
  ) {
    final role = message.role.trim().toLowerCase();
    return message.text.trim().isNotEmpty &&
        (role == 'user' || role == 'assistant');
  }

  bool _sessionCoversMessages(
    AgentConversationSession session,
    List<AgentConversationMessage> pendingMessages,
  ) {
    final nativeMessages = session.messages
        .where(_conversationMessageParticipatesInReadback)
        .toList(growable: false);
    final pendingReadback = pendingMessages
        .where(_conversationMessageParticipatesInReadback)
        .toList(growable: false);
    if (pendingReadback.isEmpty ||
        nativeMessages.length < pendingReadback.length) {
      return false;
    }
    // The native transcript may record one assistant reply as several content
    // blocks (text before/after tool calls), so readback can carry more
    // participant messages than the live projection. The readback tail must
    // still end on the live tail; only the blocks between the live messages
    // may be extra.
    final pendingTail = pendingReadback.last;
    final nativeTail = nativeMessages.last;
    if (nativeTail.role.trim().toLowerCase() !=
            pendingTail.role.trim().toLowerCase() ||
        nativeTail.text.trim() != pendingTail.text.trim()) {
      return false;
    }
    var nativeIndex = nativeMessages.length - 2;
    for (var index = pendingReadback.length - 2; index >= 0; index -= 1) {
      final pending = pendingReadback[index];
      while (nativeIndex >= 0 &&
          (nativeMessages[nativeIndex].role.trim().toLowerCase() !=
                  pending.role.trim().toLowerCase() ||
              nativeMessages[nativeIndex].text.trim() != pending.text.trim())) {
        nativeIndex -= 1;
      }
      if (nativeIndex < 0) {
        return false;
      }
      nativeIndex -= 1;
    }
    return true;
  }

  /// Binds readback to the exact turn projection instead of provider history
  /// scans. Some CLI sessions are not guaranteed to appear in
  /// `conversations list` during the same packaged process.
  Future<bool> conversationCommitTurnBoundNativeReadback({
    required String agentId,
    required String nativeSessionId,
    required List<AgentConversationMessage> messages,
    required bool mergeWithSelectedSession,
    String workingDirectory = '',
    String localSessionId = '',
    bool locallyOwned = false,
    String sourcePath = '',
  }) {
    final normalizedAgent = agentId.trim();
    final normalizedSession = nativeSessionId.trim();
    if (normalizedAgent.isEmpty || normalizedSession.isEmpty) {
      return Future<bool>.value(false);
    }
    conversationClearNativeSessionPending(normalizedAgent);
    final previous =
        mergeWithSelectedSession &&
            selectedConversationAgentId == normalizedAgent
        ? selectedConversationSession
        : null;
    final mergedMessages =
        previous != null && previous.nativeSessionId.trim() == normalizedSession
        ? [
            ...previous.messages,
            for (final message in messages)
              if (!previous.messages.any(
                (existing) => existing.stableIdentity == message.stableIdentity,
              ))
                message,
          ]
        : messages;
    final now = DateTime.now().toUtc().toIso8601String();
    final projectedSessionId = locallyOwned
        ? (localSessionId.trim().isNotEmpty
              ? localSessionId.trim()
              : 'lico-${DateTime.now().toUtc().microsecondsSinceEpoch}')
        : normalizedSession;
    final resolvedSourcePath = sourcePath.trim().isNotEmpty
        ? sourcePath.trim()
        : previous?.sourcePath.trim() ?? '';
    final session = AgentConversationSession(
      id: projectedSessionId,
      agentId: normalizedAgent,
      title: visibleAgentConversationTitle('', mergedMessages),
      createdAt: previous?.createdAt ?? now,
      updatedAt: now,
      nativeSessionId: normalizedSession,
      adapterId: locallyOwned ? 'lico-orchestration' : '',
      sourceKind: locallyOwned ? 'lico-owned-orchestration' : '',
      sourceClient: locallyOwned ? 'licoup' : '',
      sourceClientLabel: locallyOwned ? 'LicoUp' : '',
      sourcePath: resolvedSourcePath,
      native: !locallyOwned,
      readOnly: !locallyOwned,
      messages: List<AgentConversationMessage>.unmodifiable(mergedMessages),
      messageCount: mergedMessages.length,
      sourceMessageCount: mergedMessages.length,
      workingDirectory: _conversationTurnWorkingDirectory(
        requested: workingDirectory,
        previous: previous?.workingDirectory ?? '',
      ),
    );
    // Merge into the existing catalog instead of replacing it with a single
    // turn projection. A replaceAll of `[session]` wiped every recovered
    // project directory for the agent and left only the client-owned fallback.
    final existing =
        conversationSessionsByAgent[normalizedAgent] ??
        const <AgentConversationSession>[];
    final merged = insertConversationSessionByUpdatedAt(existing, session);
    conversationCommitCatalog(
      normalizedAgent,
      ConversationSessionPage(
        sessions: merged,
        hasMore: conversationSessionsHasMoreByAgent[normalizedAgent] ?? false,
      ),
      replaceAll: true,
      updateStatus: false,
      clearLiveProjectionFromProviderReadback: false,
    );
    setSelectedConversationSessionId(normalizedAgent, projectedSessionId);
    return _conversationPersistProjection(session);
  }

  /// Keeps the provider-owned native session and the LicoUp-owned
  /// orchestration session as two views over one native identity. Native
  /// readback is authoritative for the transcript, while participant labels
  /// captured from the orchestration stream remain attached to matching
  /// messages in the local group-chat projection.
  Future<bool> conversationCommitOrchestrationMirror({
    required String ownerAgentId,
    required String localSessionId,
    required AgentConversationSession nativeSession,
    required String mainAgentId,
    required String mainAgentLabel,
  }) {
    final owner = ownerAgentId.trim();
    final localId = localSessionId.trim();
    final nativeId = nativeSession.nativeSessionId.trim().isNotEmpty
        ? nativeSession.nativeSessionId.trim()
        : nativeSession.id.trim();
    if (owner.isEmpty || localId.isEmpty || nativeId.isEmpty) {
      return Future<bool>.value(false);
    }
    AgentConversationSession? previous;
    for (final session in conversationSessionsByAgent[owner] ?? const []) {
      if (session.id == localId) {
        previous = session;
        break;
      }
    }
    if (previous == null) {
      return Future<bool>.value(false);
    }

    final lifecycleAfterUser =
        <AgentConversationMessage, List<AgentConversationMessage>>{};
    AgentConversationMessage? precedingUser;
    for (final message in previous.messages) {
      if (message.kind == AgentConversationMessageKind.user) {
        precedingUser = message;
        continue;
      }
      if (message.cardType.trim() == 'lifecycle' && precedingUser != null) {
        lifecycleAfterUser.putIfAbsent(precedingUser, () => []).add(message);
      }
    }
    final localMatches = <String, List<AgentConversationMessage>>{};
    for (final message in previous.messages) {
      final key = _conversationMessageContentKey(message);
      localMatches.putIfAbsent(key, () => []).add(message);
    }
    final consumedLocalMessages = <AgentConversationMessage>{};
    final mirroredMessages = <AgentConversationMessage>[];
    for (final nativeMessage in nativeSession.messages) {
      final matching =
          localMatches[_conversationMessageContentKey(nativeMessage)];
      AgentConversationMessage? localMatch;
      if (matching != null && matching.isNotEmpty) {
        localMatch = matching.removeAt(0);
        consumedLocalMessages.add(localMatch);
      }
      final participantSource = localMatch ?? nativeMessage;
      mirroredMessages.add(
        nativeMessage.withParticipantDefaults(
          agentId: participantSource.participantAgentId.trim().isNotEmpty
              ? participantSource.participantAgentId
              : mainAgentId,
          label: participantSource.participantLabel.trim().isNotEmpty
              ? participantSource.participantLabel
              : mainAgentLabel,
          role: participantSource.participantRole.trim().isNotEmpty
              ? participantSource.participantRole
              : 'main-agent',
        ),
      );
      if (localMatch?.kind == AgentConversationMessageKind.user) {
        for (final lifecycle in lifecycleAfterUser[localMatch] ?? const []) {
          mirroredMessages.add(lifecycle);
          consumedLocalMessages.add(lifecycle);
        }
      }
    }
    for (final localMessage in previous.messages) {
      if (consumedLocalMessages.contains(localMessage)) continue;
      final participantId = localMessage.participantAgentId.trim();
      if (participantId.isNotEmpty && participantId != mainAgentId.trim()) {
        mirroredMessages.add(localMessage);
      }
    }
    final orderedMirroredMessages = mirroredMessages;

    final now = DateTime.now().toUtc().toIso8601String();
    final session = AgentConversationSession(
      id: localId,
      agentId: owner,
      title: visibleAgentConversationTitle('', orderedMirroredMessages),
      createdAt: previous.createdAt,
      updatedAt: nativeSession.updatedAt.trim().isNotEmpty
          ? nativeSession.updatedAt
          : now,
      nativeSessionId: nativeId,
      adapterId: 'lico-orchestration',
      sourceKind: 'lico-owned-orchestration',
      sourceClient: 'licoup',
      sourceClientLabel: 'LicoUp',
      native: false,
      readOnly: false,
      messages: List<AgentConversationMessage>.unmodifiable(
        orderedMirroredMessages,
      ),
      messageCount: orderedMirroredMessages.length,
      sourceMessageCount: nativeSession.sourceMessageCount,
      workingDirectory: previous.workingDirectory,
      historyTruncated: nativeSession.historyTruncated,
      messageTreeTruncated: nativeSession.messageTreeTruncated,
    );
    conversationCommitCatalog(
      owner,
      ConversationSessionPage(sessions: [session], hasMore: false),
      replaceAll: true,
      updateStatus: false,
      clearLiveProjectionFromProviderReadback: false,
    );
    liveConversationMessagesByAgent = {
      for (final entry in liveConversationMessagesByAgent.entries)
        if (entry.key != owner) entry.key: entry.value,
    };
    return _conversationPersistProjection(session);
  }

  String _conversationMessageContentKey(AgentConversationMessage message) =>
      '${message.role.trim().toLowerCase()}\u0000${message.text.trim()}';

  /// Prefer a usable project path from [authority] when [sessions] still carry
  /// an empty, unbounded, or client-owned fallback directory for the same
  /// native/session identity.
  List<AgentConversationSession> _conversationRecoverUsableWorkingDirectories(
    List<AgentConversationSession> authority,
    List<AgentConversationSession> sessions,
  ) {
    if (authority.isEmpty || sessions.isEmpty) {
      return sessions;
    }
    final byNativeSessionId = <String, String>{};
    final bySessionId = <String, String>{};
    for (final session in authority) {
      final workingDirectory = session.workingDirectory.trim();
      if (!isUsableLocalConversationWorkingDirectory(workingDirectory)) {
        continue;
      }
      final nativeSessionId = session.nativeSessionId.trim();
      if (nativeSessionId.isNotEmpty) {
        byNativeSessionId[nativeSessionId] = workingDirectory;
      }
      final sessionId = session.id.trim();
      if (sessionId.isNotEmpty) {
        bySessionId[sessionId] = workingDirectory;
      }
    }
    if (byNativeSessionId.isEmpty && bySessionId.isEmpty) {
      return sessions;
    }

    var changed = false;
    final recovered = sessions
        .map((session) {
          if (isUsableLocalConversationWorkingDirectory(
            session.workingDirectory,
          )) {
            return session;
          }
          final nativeSessionId = session.nativeSessionId.trim();
          final workingDirectory =
              (nativeSessionId.isEmpty
                  ? null
                  : byNativeSessionId[nativeSessionId]) ??
              bySessionId[session.id.trim()] ??
              '';
          if (!isUsableLocalConversationWorkingDirectory(workingDirectory)) {
            return session;
          }
          changed = true;
          return session.withWorkingDirectory(workingDirectory);
        })
        .toList(growable: false);
    return changed
        ? List<AgentConversationSession>.unmodifiable(recovered)
        : sessions;
  }
}

String _conversationTurnWorkingDirectory({
  required String requested,
  required String previous,
}) {
  final requestedDirectory = requested.trim();
  if (isUsableLocalConversationWorkingDirectory(requestedDirectory)) {
    return requestedDirectory;
  }
  final previousDirectory = previous.trim();
  if (isUsableLocalConversationWorkingDirectory(previousDirectory)) {
    return previousDirectory;
  }
  // Never persist the client-owned fallback onto the session projection —
  // relaunch would otherwise keep treating it as the conversation cwd.
  return '';
}
