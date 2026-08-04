import 'dart:async';

import 'package:path/path.dart' as p;

import 'package:licoup/src/application/features/agents/conversation/agent_conversation_read_only_policy.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_mobile_session_controller.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_session_state_controller.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_working_directory_fallback.dart';
import 'package:licoup/src/application/features/agents/policy/conversation_session_index.dart';
import 'package:licoup/src/application/features/agents/workspace/agent_workspace_coordinator.dart';
import 'package:licoup/src/application/features/agents/orchestration/agent_orchestration_policy_controller.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/agent_dispatch_lane.dart';
import 'package:licoup/src/contracts/agent_orchestration_target.dart';
import 'package:licoup/src/contracts/target_candidate.dart';

/// Desktop history paging plus user-driven session and agent selection.
mixin AgentConversationSessionController
    on
        AgentWorkspaceCoordinator,
        AgentConversationSessionStateController,
        AgentConversationMobileSessionController,
        AgentOrchestrationPolicyController {
  @override
  Future<void> refreshConversationCatalogInternal(
    String agentId, {
    required bool foreground,
  }) async {
    if (agentId.isEmpty ||
        isAgentOrchestrationTargetId(agentId) ||
        agentWorkspaceMobileRuntime ||
        conversationSessionLoadingTargets.contains(agentId)) {
      return;
    }
    final activeKey = (
      agentId: agentId,
      sessionId: conversationCatalogRefreshKey,
    );
    if (foreground) {
      if (!conversationActiveRefreshTargets.add(activeKey)) {
        return;
      }
    } else if (!conversationBackgroundRefreshTargets.add(agentId)) {
      return;
    }

    final sequence = beginConversationRequest();
    try {
      final page = await readConversationSessionPage(
        agentId,
        offset: 0,
        pageSize: conversationSessionPageSize,
      );
      if (!canApplyConversationRequest(agentId, sequence)) {
        return;
      }
      conversationCommitCatalog(
        agentId,
        page,
        replaceAll: false,
        updateStatus: false,
      );
    } catch (_) {
      // Timer-driven refresh is silent. A later foreground request may repair
      // the stale local projection.
    } finally {
      if (foreground) {
        conversationActiveRefreshTargets.remove(activeKey);
      } else {
        conversationBackgroundRefreshTargets.remove(agentId);
      }
    }
  }

  @override
  Future<void> refreshActiveConversationSessionInternal(
    String agentId,
    String sessionId,
  ) async {
    final key = (agentId: agentId, sessionId: sessionId);
    if (!conversationActiveRefreshTargets.add(key)) {
      return;
    }
    final sequence = beginConversationRequest();
    var exactSessionFound = false;
    try {
      final page = await readConversationSessionPage(
        agentId,
        sessionId: sessionId,
        offset: 0,
        pageSize: 1,
      );
      AgentConversationSession? refreshed;
      for (final session in page.sessions) {
        if (session.id == sessionId) {
          refreshed = session;
          break;
        }
      }
      if (refreshed == null) {
        return;
      }
      exactSessionFound = true;
      if (!canApplyConversationRequest(agentId, sequence)) {
        return;
      }
      final previous = conversationSessionsByAgent[agentId] ?? const [];
      final next = insertConversationSessionByUpdatedAt(previous, refreshed);
      if (conversationSessionListsEquivalent(previous, next)) {
        return;
      }
      conversationCommitCatalog(
        agentId,
        ConversationSessionPage(
          sessions: next,
          hasMore: conversationSessionsHasMoreByAgent[agentId] ?? false,
        ),
        replaceAll: true,
        updateStatus: false,
      );
    } catch (_) {
      // Exact-session refresh is best effort. The catalog lane repairs misses.
    } finally {
      conversationActiveRefreshTargets.remove(key);
      if (!exactSessionFound &&
          selectedConversationAgentId == agentId &&
          selectedConversationSessionId == sessionId) {
        unawaited(
          refreshConversationCatalogInternal(agentId, foreground: true),
        );
      }
    }
  }

  Future<ConversationSessionPage> readConversationSessionPage(
    String agentId, {
    String sessionId = '',
    required int offset,
    required int pageSize,
    ConversationSessionProgressCallback? onProgress,
  }) async {
    final bind = _historyBindFor(agentId);
    try {
      final streamedByIdentity = <String, AgentConversationSession>{};
      var hasMore = false;
      var nextMilestoneIndex = 0;
      await for (final session in conversationGateway.streamSessions(
        agentId: agentId,
        sessionId: sessionId,
        limit: pageSize + (sessionId.isEmpty ? 1 : 0),
        offset: offset,
        bind: bind,
      )) {
        final identity = session.nativeSessionId.trim().isNotEmpty
            ? 'native:${session.nativeSessionId.trim()}'
            : 'projection:${session.id}';
        streamedByIdentity[identity] = session;
        final uniqueCount = streamedByIdentity.length;
        if (uniqueCount > pageSize) {
          hasMore = true;
          continue;
        }
        if (sessionId.isEmpty && onProgress != null) {
          while (nextMilestoneIndex <
                  conversationInitialProgressiveMilestones.length &&
              uniqueCount >=
                  conversationInitialProgressiveMilestones[nextMilestoneIndex]) {
            final milestone =
                conversationInitialProgressiveMilestones[nextMilestoneIndex];
            final progressive = sortConversationSessionsByUpdatedAt(
              streamedByIdentity.values.toList(growable: false),
            ).take(milestone).toList(growable: false);
            onProgress(
              ConversationSessionPage(sessions: progressive, hasMore: true),
            );
            nextMilestoneIndex += 1;
          }
        }
      }
      final streamed = sortConversationSessionsByUpdatedAt(
        streamedByIdentity.values.toList(growable: false),
      );
      return ConversationSessionPage(
        sessions: streamed.take(pageSize).toList(growable: false),
        hasMore: hasMore,
      );
    } catch (_) {
      final loaded = sortConversationSessionsByUpdatedAt(
        await conversationGateway.loadSessions(
          agentId: agentId,
          sessionId: sessionId,
          limit: pageSize + (sessionId.isEmpty ? 1 : 0),
          offset: offset,
          bind: bind,
        ),
      );
      return ConversationSessionPage(
        sessions: loaded.take(pageSize).toList(growable: false),
        hasMore: sessionId.isEmpty && loaded.length > pageSize,
      );
    }
  }

  AgentDispatchBind _historyBindFor(String agentId) {
    TargetCandidate? candidate;
    for (final target in scannedTargets) {
      if (target.target == agentId) {
        candidate = target;
        break;
      }
    }
    if (candidate?.hasValidVirtualMachineConnection != true) {
      return const AgentDispatchBind();
    }
    return AgentDispatchBind(
      workingDirectory: candidate!.remoteWorkingDirectory,
      runtimeConnection: candidate.runtimeConnection,
    );
  }

  Future<void> loadMoreConversationSessions(String agentId) async {
    final normalized = agentId.trim();
    if (agentWorkspaceMobileRuntime) {
      await loadMoreMobileConversationSessions(normalized);
      return;
    }
    if (normalized.isEmpty ||
        isAgentOrchestrationTargetId(normalized) ||
        isLoadingConversations ||
        conversationSessionLoadMoreTargets.contains(normalized) ||
        !(conversationSessionsHasMoreByAgent[normalized] ?? false)) {
      return;
    }
    conversationSessionLoadMoreTargets.add(normalized);
    agentWorkspaceSetLocalizedStatusMessage(
      '正在继续读取 $normalized 原生历史。',
      'Continuing to read native $normalized history.',
    );
    statusCaption = 'Agent chat';
    agentWorkspaceNotifyConversationStructureChanged(activeChanged: false);
    agentWorkspaceNotifyStateChanged();
    final sequence = beginConversationRequest();
    try {
      final offset = conversationSessionsByAgent[normalized]?.length ?? 0;
      final page = await readConversationSessionPage(
        normalized,
        offset: offset,
        pageSize: conversationSessionPageSize,
      );
      if (!canApplyConversationRequest(normalized, sequence)) {
        return;
      }
      final previous = conversationSessionsByAgent[normalized] ?? const [];
      final next = mergeConversationSessionsByUpdatedAt(
        previous,
        page.sessions,
      );
      if (!conversationSessionListsEquivalent(previous, next)) {
        conversationSessionsByAgent = {
          ...conversationSessionsByAgent,
          normalized: next,
        };
      }
      conversationSessionsHasMoreByAgent = {
        ...conversationSessionsHasMoreByAgent,
        normalized: page.hasMore,
      };
      if (selectedConversationAgentId == normalized) {
        conversationReconcileSelectedSession(
          normalized,
          next,
          previous: previous,
        );
        agentWorkspaceSetLocalizedStatusMessage(
          page.hasMore
              ? '已读取 ${next.length} 条 $normalized 原生历史，滚动到底继续加载。'
              : '已读取 ${next.length} 条 $normalized 原生历史。',
          page.hasMore
              ? 'Read ${next.length} native $normalized sessions. Scroll to the bottom to load more.'
              : 'Read ${next.length} native $normalized sessions.',
        );
      }
    } finally {
      conversationSessionLoadMoreTargets.remove(normalized);
      agentWorkspaceNotifyConversationStructureChanged();
      agentWorkspaceNotifyStateChanged();
    }
  }

  /// Reconciles a completed live turn with the provider's durable history.
  ///
  /// Some runtimes acknowledge the turn before their history file is visible.
  /// The live turn remains the active, usable projection while these bounded
  /// retries run; a temporary filesystem lag must never turn a successful send
  /// into a failed or disabled conversation.
  Future<bool> reloadSelectedConversationSessionsAfterSend(
    String agentId, {
    String preferredNativeSessionId = '',
  }) async {
    final preferred = preferredNativeSessionId.trim();
    bool stillOwnsActiveSelection() {
      if (preferred.isEmpty) return true;
      if (selectedConversationAgentId != agentId ||
          newConversationDraftTokenFor(agentId).isNotEmpty) {
        return false;
      }
      final selectedId = selectedConversationSessionId.trim();
      if (selectedId.isEmpty) return false;
      if (selectedId == preferred) return true;
      for (final session in conversationSessionsByAgent[agentId] ?? const []) {
        if (session.id != selectedId) continue;
        final nativeId = session.nativeSessionId.trim();
        return nativeId.isNotEmpty && nativeId == preferred;
      }
      return false;
    }

    const retryDelays = <Duration>[
      Duration.zero,
      Duration(milliseconds: 200),
      Duration(milliseconds: 400),
      Duration(milliseconds: 800),
      Duration(milliseconds: 1600),
      Duration(milliseconds: 3200),
    ];
    for (final delay in retryDelays) {
      if (delay > Duration.zero) {
        await Future<void>.delayed(delay);
      }
      if (agentWorkspaceDisposed || !stillOwnsActiveSelection()) return false;
      try {
        final page = preferred.isEmpty
            ? await readConversationSessionPage(
                agentId,
                offset: 0,
                pageSize: conversationSessionPageSize,
              )
            : await readConversationSessionPage(
                agentId,
                sessionId: preferred,
                offset: 0,
                pageSize: 1,
              );
        final exactReadback = preferred.isEmpty
            ? page.sessions.isNotEmpty
            : page.sessions.any(
                (session) => session.nativeSessionId.trim() == preferred,
              );
        if (!exactReadback) continue;
        if (!stillOwnsActiveSelection()) return false;
        final committedPage = preferred.isEmpty
            ? page
            : ConversationSessionPage(
                sessions: mergeConversationSessionsByUpdatedAt(
                  conversationSessionsByAgent[agentId] ?? const [],
                  page.sessions,
                ),
                hasMore: conversationSessionsHasMoreByAgent[agentId] ?? false,
              );
        conversationCommitCatalog(
          agentId,
          committedPage,
          replaceAll: true,
          updateStatus: false,
        );
        await conversationFlushProjectionPersistence();
        return true;
      } catch (_) {
        // Durable history may still be committing. Retry without changing the
        // already successful send state or disabling the composer.
      }
    }
    return false;
  }

  /// Reads one provider-native session back into both catalogs: the provider
  /// keeps its ordinary native history entry, and the LicoUp orchestration
  /// owner receives a cleaned participant-aware mirror of the same session.
  Future<bool> reloadDualConversationSessionsAfterSend({
    required String ownerAgentId,
    required String localSessionId,
    required String nativeAgentId,
    required String nativeSessionId,
    required String nativeAgentLabel,
  }) async {
    final owner = ownerAgentId.trim();
    final localId = localSessionId.trim();
    final nativeAgent = nativeAgentId.trim();
    final nativeId = nativeSessionId.trim();
    if (owner.isEmpty ||
        localId.isEmpty ||
        nativeAgent.isEmpty ||
        nativeId.isEmpty) {
      return false;
    }
    const retryDelays = <Duration>[
      Duration.zero,
      Duration(milliseconds: 200),
      Duration(milliseconds: 400),
      Duration(milliseconds: 800),
      Duration(milliseconds: 1600),
      Duration(milliseconds: 3200),
    ];
    for (final delay in retryDelays) {
      if (delay > Duration.zero) {
        await Future<void>.delayed(delay);
      }
      if (agentWorkspaceDisposed) return false;
      try {
        final page = await readConversationSessionPage(
          nativeAgent,
          sessionId: nativeId,
          offset: 0,
          pageSize: 1,
        );
        AgentConversationSession? nativeSession;
        for (final session in page.sessions) {
          final sessionNativeId = session.nativeSessionId.trim().isNotEmpty
              ? session.nativeSessionId.trim()
              : session.id.trim();
          if (sessionNativeId == nativeId) {
            nativeSession = session;
            break;
          }
        }
        if (nativeSession == null) continue;

        conversationCommitCatalog(
          nativeAgent,
          ConversationSessionPage(
            sessions: mergeConversationSessionsByUpdatedAt(
              conversationSessionsByAgent[nativeAgent] ?? const [],
              [nativeSession],
            ),
            hasMore: conversationSessionsHasMoreByAgent[nativeAgent] ?? false,
          ),
          replaceAll: true,
          updateStatus: false,
        );
        final mirrored = await conversationCommitOrchestrationMirror(
          ownerAgentId: owner,
          localSessionId: localId,
          nativeSession: nativeSession,
          mainAgentId: nativeAgent,
          mainAgentLabel: nativeAgentLabel,
        );
        await conversationFlushProjectionPersistence();
        return mirrored;
      } catch (_) {
        // Provider history may be committed shortly after the turn result.
        // The already visible local turn remains usable during bounded retry.
      }
    }
    return false;
  }

  void selectConversationSession(String sessionId) {
    conversationClearNativeSessionPending(selectedConversationAgentId);
    abandonNewConversationDraft(selectedConversationAgentId);
    selectedConversationSessionId = sessionId;
    agentWorkspaceNotifyConversationStructureChanged();
    agentWorkspaceNotifyStateChanged();
    conversationAttentionContextChanged();
  }

  String get selectedConversationWorkingDirectory {
    final agent = selectedConversationAgent;
    if (agent == null || selectedConversationIsOrchestration) {
      return '';
    }
    if (agent.hasValidVirtualMachineConnection) {
      return agent.remoteWorkingDirectory.trim();
    }
    if (preparingNewConversation) {
      final draftDirectory =
          (newConversationWorkingDirectories[agent.target] ?? '').trim();
      if (isUsableLocalConversationWorkingDirectory(draftDirectory)) {
        return draftDirectory;
      }
    } else {
      final sessionDirectory =
          selectedConversationSession?.workingDirectory.trim() ?? '';
      if (isUsableLocalConversationWorkingDirectory(sessionDirectory)) {
        return sessionDirectory;
      }
    }
    final historicalDirectory = historicalConversationWorkingDirectory(
      conversationSessionsByAgent[agent.target] ?? const [],
    );
    if (historicalDirectory.isNotEmpty) {
      return historicalDirectory;
    }
    final remoteDirectory = agent.remoteWorkingDirectory.trim();
    if (isUsableLocalConversationWorkingDirectory(remoteDirectory)) {
      return remoteDirectory;
    }
    return localConversationWorkingDirectoryFallback(agentId: agent.target);
  }

  bool get canSelectNewConversationWorkingDirectory {
    final agent = selectedConversationAgent;
    return agent != null &&
        !agentWorkspaceMobileRuntime &&
        !selectedConversationIsOrchestration &&
        !agent.hasValidVirtualMachineConnection &&
        preparingNewConversation &&
        !isSendingConversationMessage;
  }

  void selectNewConversationWorkingDirectory(String path) {
    final agent = selectedConversationAgent;
    if (agent == null || !canSelectNewConversationWorkingDirectory) {
      return;
    }
    final normalized = path.trim();
    if (isUnboundedLocalAgentWorkspace(normalized)) {
      lastError = 'conversation_working_directory_unbounded';
      agentWorkspaceSetLocalizedStatusMessage(
        '所选目录是个人目录树的根，代理会索引其中全部文件，请改选具体项目目录。',
        'The selected directory is the root of a personal tree that the agent '
            'would index in full. Choose a specific project directory instead.',
      );
      statusCaption = 'Agent chat';
      agentWorkspaceNotifyActiveConversationChanged();
      agentWorkspaceNotifyStateChanged();
      return;
    }
    if (!_validLocalConversationWorkingDirectory(normalized)) {
      lastError = 'conversation_working_directory_invalid';
      agentWorkspaceSetLocalizedStatusMessage(
        '所选工作目录无效，已保留当前选择。',
        'The selected working directory is invalid. The current selection was kept.',
      );
      statusCaption = 'Agent chat';
      agentWorkspaceNotifyActiveConversationChanged();
      agentWorkspaceNotifyStateChanged();
      return;
    }
    newConversationWorkingDirectories = {
      ...newConversationWorkingDirectories,
      agent.target: normalized,
    };
    lastError = '';
    agentWorkspaceSetLocalizedStatusMessage(
      '已更新新对话的工作目录。',
      'Updated the working directory for the new conversation.',
    );
    statusCaption = 'Agent chat';
    agentWorkspaceNotifyActiveConversationChanged();
    agentWorkspaceNotifyStateChanged();
  }

  /// Primes the new-conversation draft for the selected agent: the first sent
  /// message creates its session in a historical working directory.
  ///
  /// Prefer the currently selected session's cwd, then the newest usable cwd
  /// across that agent's loaded history. Desktop selects an agent before its
  /// session list finishes loading, so [conversationCommitCatalog] re-invokes
  /// this once history arrives when the draft is still empty.
  void conversationPrimeNewConversationDraft() {
    final agent = selectedConversationAgent;
    if (agent == null) {
      return;
    }
    final existingDraft =
        (newConversationWorkingDirectories[agent.target] ?? '').trim();
    if (isUsableLocalConversationWorkingDirectory(existingDraft)) {
      return;
    }
    final selectedDirectory =
        selectedConversationSession?.workingDirectory.trim() ?? '';
    final previousWorkingDirectory =
        isUsableLocalConversationWorkingDirectory(selectedDirectory)
        ? selectedDirectory
        : historicalConversationWorkingDirectory(
            conversationSessionsByAgent[agent.target] ?? const [],
          );
    if (previousWorkingDirectory.isEmpty) {
      return;
    }
    newConversationWorkingDirectories = {
      ...newConversationWorkingDirectories,
      agent.target: previousWorkingDirectory,
    };
  }

  @override
  bool conversationCommitCatalog(
    String agentId,
    ConversationSessionPage page, {
    required bool replaceAll,
    required bool updateStatus,
    bool notifyChanges = true,
    bool clearLiveProjectionFromProviderReadback = true,
  }) {
    final changed = super.conversationCommitCatalog(
      agentId,
      page,
      replaceAll: replaceAll,
      updateStatus: updateStatus,
      notifyChanges: notifyChanges,
      clearLiveProjectionFromProviderReadback:
          clearLiveProjectionFromProviderReadback,
    );
    if (selectedConversationAgentId == agentId && preparingNewConversation) {
      conversationPrimeNewConversationDraft();
    }
    return changed;
  }

  void startNewConversationSession() {
    final agent = selectedConversationAgent;
    if (agent == null) {
      return;
    }
    conversationClearNativeSessionPending(agent.target);
    conversationPrimeNewConversationDraft();
    liveConversationMessagesByAgent = {
      for (final entry in liveConversationMessagesByAgent.entries)
        if (entry.key != agent.target) entry.key: entry.value,
    };
    selectedConversationSessionId = '';
    beginNewConversationDraft(agent.target);
    lastError = '';
    agentWorkspaceSetLocalizedStatusMessage(
      '已准备 ${agent.label} 新对话，发送首条消息后创建。',
      'A new ${agent.label} conversation is ready and will be created after you send the first message.',
    );
    statusCaption = 'Agent chat';
    agentWorkspaceNotifyConversationStructureChanged();
    agentWorkspaceNotifyStateChanged();
    conversationAttentionContextChanged(immediateActive: false);
  }

  Future<void> deleteConversationSession(String sessionId) async {
    final agentId = selectedConversationAgentId;
    if (agentId.isEmpty || sessionId.isEmpty) {
      return;
    }
    lastError = nativeConversationReadOnlyMessageZh;
    agentWorkspaceSetLocalizedStatusMessage(
      '原生历史只读，未删除源会话。',
      'Native history is read-only; the source session was not deleted.',
    );
    statusCaption = 'Agent chat';
    agentWorkspaceNotifyStateChanged();
  }

  Future<void> selectConversationAgent(String agentId) async {
    final normalizedAgentId = agentId.trim();
    if (isAgentOrchestrationTargetId(normalizedAgentId)) {
      if (!orchestrationAvailable) {
        return;
      }
      acknowledgeConversationTabWorkFinished(agentOrchestrationTargetId);
      selectedConversationAgentId = agentOrchestrationTargetId;
      stopConversationRefreshScheduling();
      agentWorkspaceSetLocalizedStatusMessage(
        '已切换到默认智能体编排。',
        'Switched to the default agent orchestration.',
      );
      statusCaption = 'Agent orchestration';
      agentWorkspaceNotifyConversationStructureChanged();
      agentWorkspaceNotifyStateChanged();
      return;
    }
    if (normalizedAgentId.isEmpty) {
      return;
    }
    if (normalizedAgentId == selectedConversationAgentId &&
        selectedConversationSessions.isNotEmpty) {
      if (!agentWorkspaceMobileRuntime) {
        await agentWorkspaceEnsureConversationRuntimeBinding(normalizedAgentId);
        if (agentWorkspaceDisposed ||
            selectedConversationAgentId != normalizedAgentId) {
          return;
        }
      }
      // Cached/durable sessions often lack a real project cwd (or still carry
      // the retired agent-workspaces fallback). Refresh native history so the
      // composer can bind the trusted workspace path from Cursor projects.
      final hasUsableWorkingDirectory =
          (conversationSessionsByAgent[normalizedAgentId] ?? const []).any(
            (session) => isUsableLocalConversationWorkingDirectory(
              session.workingDirectory,
            ),
          );
      if (!hasUsableWorkingDirectory) {
        await loadConversationSessions(normalizedAgentId);
        if (agentWorkspaceDisposed ||
            selectedConversationAgentId != normalizedAgentId) {
          return;
        }
        conversationPrimeNewConversationDraft();
      }
      acknowledgeConversationTabWorkFinished(normalizedAgentId);
      conversationAttentionContextChanged();
      agentWorkspaceNotifyStateChanged();
      return;
    }

    acknowledgeConversationTabWorkFinished(normalizedAgentId);
    selectedConversationAgentId = normalizedAgentId;
    agentWorkspaceSetLocalizedStatusMessage(
      '正在读取 $normalizedAgentId 原生历史。',
      'Reading native $normalizedAgentId history.',
    );
    statusCaption = 'Agent chat';
    if (agentWorkspaceMobileRuntime) {
      abandonNewConversationDraft(normalizedAgentId);
      agentWorkspaceNotifyConversationStructureChanged();
      agentWorkspaceNotifyStateChanged();
      stopConversationRefreshScheduling();
      await loadConversationSessions(normalizedAgentId);
      return;
    }
    // Desktop lands on the new-conversation home instead of auto-opening the
    // most recent session; the recent list loads in the background.
    conversationPrimeNewConversationDraft();
    selectedConversationSessionId = '';
    beginNewConversationDraft(normalizedAgentId);
    agentWorkspaceNotifyConversationStructureChanged();
    agentWorkspaceNotifyStateChanged();
    await agentWorkspaceEnsureConversationRuntimeBinding(normalizedAgentId);
    if (agentWorkspaceDisposed ||
        selectedConversationAgentId != normalizedAgentId) {
      return;
    }
    if ((conversationSessionsByAgent[normalizedAgentId] ?? const [])
        .isNotEmpty) {
      conversationAttentionContextChanged();
      return;
    }
    await loadConversationSessions(normalizedAgentId);
  }

  Future<void> loadConversationSessions(String agentId) async {
    final normalizedAgentId = agentId.trim();
    if (normalizedAgentId.isEmpty ||
        conversationSessionLoadingTargets.contains(normalizedAgentId)) {
      return;
    }
    if (isAgentOrchestrationTargetId(normalizedAgentId)) {
      if (!orchestrationAvailable) {
        return;
      }
      stopConversationRefreshScheduling();
      conversationSessionsHasMoreByAgent = {
        ...conversationSessionsHasMoreByAgent,
        agentOrchestrationTargetId: false,
      };
      agentWorkspaceNotifyConversationStructureChanged();
      agentWorkspaceNotifyStateChanged();
      return;
    }
    if (agentWorkspaceMobileRuntime) {
      stopConversationRefreshScheduling();
      await loadMobileConversationSessions(normalizedAgentId);
      return;
    }

    conversationSessionLoadingTargets.add(normalizedAgentId);
    if (selectedConversationAgentId == normalizedAgentId) {
      lastError = '';
      agentWorkspaceNotifyConversationStructureChanged(activeChanged: false);
      agentWorkspaceNotifyStateChanged();
    }
    final sequence = beginConversationRequest();
    try {
      final page = await readConversationSessionPage(
        normalizedAgentId,
        offset: 0,
        pageSize: conversationSessionPageSize,
        onProgress: (progress) {
          if (!canApplyConversationRequest(normalizedAgentId, sequence)) {
            return;
          }
          conversationCommitCatalog(
            normalizedAgentId,
            progress,
            replaceAll: true,
            updateStatus: false,
          );
        },
      );
      if (!canApplyConversationRequest(normalizedAgentId, sequence)) {
        return;
      }
      conversationCommitCatalog(
        normalizedAgentId,
        page,
        replaceAll: true,
        updateStatus: selectedConversationAgentId == normalizedAgentId,
        notifyChanges: false,
      );
    } catch (_) {
      if (selectedConversationAgentId == normalizedAgentId) {
        lastError = 'native_history_load_failed';
        agentWorkspaceSetLocalizedStatusMessage(
          '$normalizedAgentId 原生历史读取失败。',
          'Failed to read native $normalizedAgentId history.',
        );
        statusCaption = 'Agent chat';
        if (conversationPendingNativeSessionId(normalizedAgentId).isNotEmpty) {
          selectedConversationSessionId =
              conversationSessionReadbackPendingSelectionId;
        } else if (selectedConversationSessions.isEmpty) {
          selectedConversationSessionId =
              conversationSessionLoadFailedSelectionId;
        }
      }
    } finally {
      conversationSessionLoadingTargets.remove(normalizedAgentId);
      if (selectedConversationAgentId == normalizedAgentId) {
        agentWorkspaceNotifyConversationStructureChanged();
        agentWorkspaceNotifyStateChanged();
        conversationAttentionContextChanged(immediateActive: false);
      }
    }
  }

  Future<void> refreshConversationSessions(String agentId) {
    return refreshConversationCatalogInternal(agentId.trim(), foreground: true);
  }
}

bool _validLocalConversationWorkingDirectory(String value) {
  return value.isNotEmpty &&
      value.length <= 4096 &&
      p.isAbsolute(value) &&
      !value.contains(RegExp(r'[\u0000-\u001f\u007f]'));
}
