import 'dart:async';

import 'package:path/path.dart' as p;

import 'package:licoup/src/application/features/agents/conversation/agent_conversation_read_only_policy.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_mobile_session_controller.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_session_state_controller.dart';
import 'package:licoup/src/application/features/agents/conversation/conversation_working_directory_fallback.dart';
import 'package:licoup/src/application/features/agents/policy/conversation_session_index.dart';
import 'package:licoup/src/application/features/agents/workspace/agent_workspace_coordinator.dart';
import 'package:licoup/src/contracts/agent_conversation_models.dart';
import 'package:licoup/src/contracts/agent_dispatch_lane.dart';
import 'package:licoup/src/contracts/target_candidate.dart';

/// Desktop history paging plus user-driven session and agent selection.
mixin AgentConversationSessionController
    on
        AgentWorkspaceCoordinator,
        AgentConversationSessionStateController,
        AgentConversationMobileSessionController {
  @override
  Future<void> refreshConversationCatalogInternal(
    String agentId, {
    required bool foreground,
  }) async {
    if (agentId.isEmpty ||
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
        if (session.id == sessionId ||
            session.nativeSessionId.trim() == sessionId) {
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
    // The sidebar hands over the display id, while the native reader matches
    // the stable native session id. Resolving against the local catalog keeps
    // an exact-session read on the full transcript instead of falling back to
    // the 50-message browse preview (which drops cards placed mid-conversation).
    final resolvedSessionId =
        _resolveNativeSessionIdForRead(agentId, sessionId) ?? sessionId;
    try {
      final streamedByIdentity = <String, AgentConversationSession>{};
      var hasMore = false;
      var nextMilestoneIndex = 0;
      await for (final session in conversationGateway.streamSessions(
        agentId: agentId,
        sessionId: resolvedSessionId,
        limit: pageSize + (resolvedSessionId.isEmpty ? 1 : 0),
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
          sessionId: resolvedSessionId,
          limit: pageSize + (resolvedSessionId.isEmpty ? 1 : 0),
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
    final completedLoadMoreCount =
        conversationSessionLoadMoreCountsByAgent[normalized] ?? 0;
    final pageSize = conversationSessionLoadMorePageSize(
      completedLoadMoreCount,
    );
    try {
      final offset = conversationSessionsByAgent[normalized]?.length ?? 0;
      final page = await readConversationSessionPage(
        normalized,
        offset: offset,
        pageSize: pageSize,
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
      conversationSessionLoadMoreCountsByAgent = {
        ...conversationSessionLoadMoreCountsByAgent,
        normalized: completedLoadMoreCount + 1,
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
        return true;
      } catch (_) {
        // Durable history may still be committing. Retry without changing the
        // already successful send state or disabling the composer.
      }
    }
    return false;
  }

  void selectConversationSession(String sessionId) {
    final normalizedSessionId = sessionId.trim();
    final activeNativeSessionId = sendingConversationNativeSessionId.trim();
    final selectedAgentId =
        selectedConversationAgent?.target.trim() ??
        selectedConversationAgentId.trim();
    final selectsActiveNewConversation =
        preparingNewConversation &&
        isSendingConversationMessage &&
        selectedAgentId == sendingConversationAgentId.trim() &&
        selectedConversationSessions.any((session) {
          if (session.id.trim() != normalizedSessionId) return false;
          final nativeSessionId = session.nativeSessionId.trim();
          return (sendingConversationSessionId.trim().isNotEmpty &&
                  session.id.trim() == sendingConversationSessionId.trim()) ||
              (activeNativeSessionId.isNotEmpty &&
                  (nativeSessionId == activeNativeSessionId ||
                      session.id.trim() == activeNativeSessionId));
        });
    if (!selectsActiveNewConversation) {
      conversationClearNativeSessionPending(selectedConversationAgentId);
      abandonNewConversationDraft(selectedConversationAgentId);
    }
    clearConversationWorkingDirectoryOverride();
    selectedConversationSessionId = normalizedSessionId;
    agentWorkspaceNotifyConversationStructureChanged();
    agentWorkspaceNotifyStateChanged();
    conversationAttentionContextChanged();
    agentWorkspaceRecordCurrentAgentView();
  }

  String get selectedConversationWorkingDirectory {
    final agent = selectedConversationAgent;
    if (agent == null) return '';
    if (agent.hasValidVirtualMachineConnection) {
      return agent.remoteWorkingDirectory.trim();
    }
    final agentSessions = conversationSessionsByAgent[agent.target] ?? const [];
    // Explicit user bind for the next turn wins over session provenance and
    // the shared client-owned fallback.
    final draftDirectory =
        (newConversationWorkingDirectories[agent.target] ?? '').trim();
    if (isBoundableConversationWorkingDirectory(draftDirectory)) {
      return draftDirectory;
    }
    if (!preparingNewConversation) {
      final sessionDirectory =
          selectedConversationSession?.workingDirectory.trim() ?? '';
      if (isUsableLocalConversationWorkingDirectory(sessionDirectory)) {
        return sessionDirectory;
      }
      // Same native identity may appear twice (turn projection + catalog).
      // Prefer the catalog copy's project directory before agent-wide history.
      final selectedNativeId =
          selectedConversationSession?.nativeSessionId.trim() ?? '';
      if (selectedNativeId.isNotEmpty) {
        for (final session in agentSessions) {
          if (session.nativeSessionId.trim() != selectedNativeId) {
            continue;
          }
          final directory = session.workingDirectory.trim();
          if (isUsableLocalConversationWorkingDirectory(directory)) {
            return directory;
          }
        }
      }
    }
    final historicalDirectory = historicalConversationWorkingDirectory(
      agentSessions,
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

  /// Local desktop agents may always rebind the next-turn working directory.
  /// The composer defaults to the shared client-owned `agent-workspace` and
  /// must stay clickable — never locked — so the user can pick a project.
  /// Sending a turn does not lock the capsule; the bind applies to later turns.
  bool get canSelectNewConversationWorkingDirectory {
    final agent = selectedConversationAgent;
    return agent != null &&
        !agentWorkspaceMobileRuntime &&
        !agent.hasValidVirtualMachineConnection;
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
      '已更新工作目录。',
      'Updated the working directory.',
    );
    statusCaption = 'Agent chat';
    agentWorkspaceNotifyActiveConversationChanged();
    agentWorkspaceNotifyStateChanged();
  }

  /// Drops a pending next-turn working-directory bind for the selected agent.
  void clearConversationWorkingDirectoryOverride() {
    final agent = selectedConversationAgent;
    final key = agent?.target.trim() ?? '';
    if (key.isEmpty || !newConversationWorkingDirectories.containsKey(key)) {
      return;
    }
    newConversationWorkingDirectories = {
      for (final entry in newConversationWorkingDirectories.entries)
        if (entry.key != key) entry.key: entry.value,
    };
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
    if (isBoundableConversationWorkingDirectory(existingDraft)) {
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
    final clearedScopes = conversationLiveScopeKeysForAgent(
      agent.target,
    ).toSet();
    if (clearedScopes.isNotEmpty) {
      conversationTurnProcessStateByScope = {
        for (final entry in conversationTurnProcessStateByScope.entries)
          if (!clearedScopes.contains(entry.key)) entry.key: entry.value,
      };
      liveConversationMessagesByScope = {
        for (final entry in liveConversationMessagesByScope.entries)
          if (!clearedScopes.contains(entry.key)) entry.key: entry.value,
      };
    }
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
    agentWorkspaceRecordCurrentAgentView();
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
    if (normalizedAgentId.isEmpty) {
      return;
    }
    if (normalizedAgentId == selectedConversationAgentId &&
        selectedConversationSessions.isNotEmpty) {
      var runtimeBound = true;
      if (!agentWorkspaceMobileRuntime) {
        runtimeBound = await agentWorkspaceEnsureConversationRuntimeBinding(
          normalizedAgentId,
        );
        if (agentWorkspaceDisposed ||
            selectedConversationAgentId != normalizedAgentId) {
          return;
        }
      }
      // Cached sessions often lack a project cwd. Refresh native history only
      // after the Agent executable is bound; a failed rebind must keep the
      // cached list instead of walking the host store.
      final hasBoundableWorkingDirectory =
          (conversationSessionsByAgent[normalizedAgentId] ?? const []).any(
            (session) => isBoundableConversationWorkingDirectory(
              session.workingDirectory,
            ),
          );
      if (runtimeBound && !hasBoundableWorkingDirectory) {
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
      agentWorkspaceRecordCurrentAgentView();
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
      agentWorkspaceRecordCurrentAgentView();
      return;
    }
    // Desktop lands on the new-conversation home instead of auto-opening the
    // most recent session; the recent list loads in the background.
    conversationPrimeNewConversationDraft();
    selectedConversationSessionId = '';
    beginNewConversationDraft(normalizedAgentId);
    agentWorkspaceRecordCurrentAgentView();
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
      agentWorkspaceRecordCurrentAgentView();
      return;
    }
    await loadConversationSessions(normalizedAgentId);
    agentWorkspaceRecordCurrentAgentView();
  }

  Future<void> loadConversationSessions(String agentId) async {
    final normalizedAgentId = agentId.trim();
    if (normalizedAgentId.isEmpty ||
        conversationSessionLoadingTargets.contains(normalizedAgentId)) {
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
      conversationSessionLoadMoreCountsByAgent = {
        ...conversationSessionLoadMoreCountsByAgent,
        normalizedAgentId: 0,
      };
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
        _confirmCurrentViewRestore(normalizedAgentId);
        agentWorkspaceNotifyConversationStructureChanged();
        agentWorkspaceNotifyStateChanged();
        conversationAttentionContextChanged(immediateActive: false);
      }
    }
  }

  /// Confirms the globally restored session against the loaded history once
  /// the session list arrives: reopen the restored session when it still
  /// exists, otherwise keep the newest session the reconciliation already
  /// selected.
  void _confirmCurrentViewRestore(String agentId) {
    final restoreSessionId = currentViewRestoreSessionId.trim();
    if (restoreSessionId.isEmpty) {
      return;
    }
    currentViewRestoreSessionId = '';
    final sessions = conversationSessionsByAgent[agentId] ?? const [];
    AgentConversationSession? restored;
    for (final session in sessions) {
      if (session.id == restoreSessionId ||
          session.nativeSessionId.trim() == restoreSessionId) {
        restored = session;
        break;
      }
    }
    if (restored != null) {
      setSelectedConversationSessionId(agentId, restored.id);
    }
  }

  /// Applies an Agent selection from the global current-view snapshot.
  bool restoreCurrentAgentView(String agentId, String sessionId) {
    final normalizedAgentId = agentId.trim();
    if (normalizedAgentId.isEmpty) return false;
    final visibleTargets = scannedTargets
        .where((target) => target.isConversationAgent)
        .toList(growable: false);
    if (!visibleTargets.any((target) => target.target == normalizedAgentId)) {
      return false;
    }
    selectedConversationAgentId = normalizedAgentId;
    final normalizedSessionId = sessionId.trim();
    if (normalizedSessionId.isNotEmpty) {
      final loaded = conversationSessionsByAgent[normalizedAgentId] ?? const [];
      if (loaded.any((session) => session.id == normalizedSessionId)) {
        setSelectedConversationSessionId(
          normalizedAgentId,
          normalizedSessionId,
        );
      } else {
        currentViewRestoreSessionId = normalizedSessionId;
        unawaited(loadConversationSessions(normalizedAgentId));
      }
    }
    lastError = '';
    agentWorkspaceNotifyConversationStructureChanged();
    agentWorkspaceNotifyStateChanged();
    return true;
  }

  Future<void> refreshConversationSessions(String agentId) async {
    await refreshConversationCatalogInternal(agentId.trim(), foreground: true);
    conversationAttentionContextChanged(immediateActive: false);
  }

  /// Maps a display session id to the stable native session id the native
  /// reader matches, when the local catalog knows the mapping. Returns null
  /// when [sessionId] is empty or the session has no native identity, so the
  /// caller keeps using the display id (catalog browse path).
  String? _resolveNativeSessionIdForRead(String agentId, String sessionId) {
    if (sessionId.isEmpty) {
      return null;
    }
    final sessions =
        conversationSessionsByAgent[agentId] ??
        const <AgentConversationSession>[];
    for (final session in sessions) {
      if (session.id == sessionId) {
        final nativeId = session.nativeSessionId.trim();
        return nativeId.isNotEmpty ? nativeId : null;
      }
    }
    return null;
  }
}

bool _validLocalConversationWorkingDirectory(String value) {
  return value.isNotEmpty &&
      value.length <= 4096 &&
      p.isAbsolute(value) &&
      !value.contains(RegExp(r'[\u0000-\u001f\u007f]'));
}
