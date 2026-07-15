part of 'package:flutter_client/src/application/controller/client_controller.dart';

const int _maxFeedSessionsPerAgent = 20;
const int _maxFeedDispatchTargets = 16;
const int _maxFeedDispatchAttempts = 3;
const int _maxFeedAttachments = 8;
const int _maxFeedAttachmentBytes = 256 * 1024;
const int _maxFeedAttachmentTotalBytes = 512 * 1024;

extension ClientControllerFeedActions on ClientController {
  Future<void> loadFeedTimeline() async {
    feedTimeline = await agentFeedService.load(portableData);
    _notifyStateChanged();
  }

  Future<void> saveFeedTimeline() async {
    await agentFeedService.save(portableData, feedTimeline);
  }

  /// Refreshes feed posts from all known conversation sessions. Idempotent:
  /// posts are keyed by sourceAgentId + sourceSessionId.
  Future<void> refreshFeedPosts() async {
    final sessionsByAgent = conversationSessionsByAgent;
    if (sessionsByAgent.isEmpty) {
      return;
    }
    var timeline = feedTimeline;
    for (final entry in sessionsByAgent.entries) {
      timeline = _refreshFeedPostsForAgentId(entry.key, entry.value, timeline);
    }
    if (timeline != feedTimeline) {
      feedTimeline = timeline;
      _notifyStateChanged();
      await saveFeedTimeline();
    }
  }

  Future<void> refreshFeedPostsForAgent(String agentId) async {
    final sessions = conversationSessionsByAgent[agentId];
    if (sessions == null || sessions.isEmpty) {
      return;
    }
    final timeline = _refreshFeedPostsForAgentId(
      agentId,
      sessions,
      feedTimeline,
    );
    if (timeline != feedTimeline) {
      feedTimeline = timeline;
      _notifyStateChanged();
      await saveFeedTimeline();
    }
  }

  /// Creates a user-authored home-feed post and dispatches work to mentioned
  /// agents. When no agents are mentioned, routes through the default
  /// orchestrator when available.
  Future<void> createUserFeedPost({
    required String body,
    List<String> mentionedAgentIds = const [],
    List<String> attachmentPaths = const [],
  }) async {
    final selectedAttachmentPaths = attachmentPaths
        .map((path) => path.trim())
        .where((path) => path.isNotEmpty)
        .toList(growable: false);
    final attachments = await _prepareFeedAttachments(selectedAttachmentPaths);
    final normalized = _composeFeedPostBody(body, attachments);
    if (normalized.isEmpty) {
      return;
    }
    final now = DateTime.now().toUtc().toIso8601String();
    final mentionIds = mentionedAgentIds
        .map((id) => id.trim())
        .where((id) => id.isNotEmpty)
        .toSet()
        .take(_maxFeedDispatchTargets)
        .toList(growable: false);
    final title = mentionIds.isEmpty
        ? normalized
        : _userFeedPostTitle(normalized, mentionIds);
    final dispatchId = 'dispatch-$now-${_randomSuffix()}';
    final directDefaultAgentId =
        selectedConversationAgentId.isNotEmpty &&
            !isAgentOrchestrationTargetId(selectedConversationAgentId)
        ? selectedConversationAgentId
        : scannedTargets
              .where(
                (target) =>
                    target.isConversationAgent && target.canRelayRuntime,
              )
              .map((target) => target.target)
              .firstOrNull;
    final dispatchIds = mentionIds.isNotEmpty
        ? mentionIds
        : routingModuleAvailable
        ? <String>[agentOrchestrationTargetId]
        : directDefaultAgentId == null
        ? const <String>[]
        : <String>[directDefaultAgentId];
    final prompt = _composeFeedPostBody(_stripMentionTokens(body), attachments);
    var post = AgentFeedPost(
      id: 'post:user:$now-${_randomSuffix()}',
      author: _currentUserFeedAuthor(),
      createdAt: now,
      updatedAt: now,
      title: title.length > 80 ? '${title.substring(0, 77)}…' : title,
      body: normalized,
      dispatchText: prompt,
      sourceAgentId: dispatchIds.isEmpty ? '' : dispatchIds.first,
      sourceAgentIds: dispatchIds,
      sourceSessionId: '',
      dispatchId: dispatchId,
      attachments: attachments,
      status: dispatchIds.isEmpty
          ? AgentFeedPostStatus.error
          : AgentFeedPostStatus.working,
    );
    final outcomes = [
      for (final targetId in dispatchIds)
        AgentFeedDispatchOutcome(
          dispatchId: dispatchId,
          targetId: targetId,
          status: AgentFeedDispatchStatus.pending,
          attemptCount: 0,
          updatedAt: now,
        ),
    ];
    post = post.copyWith(status: deriveAgentFeedPostStatus(post, outcomes));
    final posts = List<AgentFeedPost>.from(feedTimeline.posts, growable: true)
      ..insert(0, post);
    feedTimeline = feedTimeline.copyWith(
      posts: posts,
      dispatchOutcomes: [...feedTimeline.dispatchOutcomes, ...outcomes],
    );
    _notifyStateChanged();
    await saveFeedTimeline();

    for (final agentId in dispatchIds) {
      await _dispatchFeedTarget(post.id, agentId);
    }
  }

  String _composeFeedPostBody(
    String body,
    List<AgentFeedAttachment> attachments,
  ) {
    final text = body.trim();
    if (attachments.isEmpty) {
      return text;
    }
    final buffer = StringBuffer();
    if (text.isNotEmpty) {
      buffer.writeln(text);
      buffer.writeln();
    }
    buffer.writeln('--- attachments ---');
    for (final attachment in attachments) {
      if (attachment.accepted) {
        buffer.writeln(
          '${attachment.name} (${attachment.mediaType}; '
          '${attachment.byteLength} bytes):',
        );
        buffer.writeln(attachment.content);
        buffer.writeln();
      } else {
        buffer.writeln(
          '- ${attachment.name} (rejected: ${attachment.errorCode})',
        );
      }
    }
    return buffer.toString().trim();
  }

  Future<List<AgentFeedAttachment>> _prepareFeedAttachments(
    List<String> paths,
  ) async {
    final prepared = <AgentFeedAttachment>[];
    var acceptedBytes = 0;
    final boundedPaths = paths
        .take(_maxFeedAttachments)
        .toList(growable: false);
    for (var index = 0; index < boundedPaths.length; index += 1) {
      final attachment = await _prepareFeedAttachment(
        boundedPaths[index],
        index,
        remainingBytes: _maxFeedAttachmentTotalBytes - acceptedBytes,
      );
      prepared.add(attachment);
      if (attachment.accepted) {
        acceptedBytes += attachment.byteLength;
      }
    }
    if (paths.length > _maxFeedAttachments) {
      prepared.add(
        AgentFeedAttachment(
          id: 'attachment-limit-${_randomSuffix()}',
          name: '${paths.length - _maxFeedAttachments} additional files',
          mediaType: 'application/octet-stream',
          encoding: '',
          byteLength: 0,
          privacy: 'explicit-user-selection',
          transfer: AgentFeedAttachmentTransfer.rejected,
          errorCode: 'attachment_count_exceeded',
        ),
      );
    }
    return List.unmodifiable(prepared);
  }

  Future<AgentFeedAttachment> _prepareFeedAttachment(
    String path,
    int index, {
    required int remainingBytes,
  }) async {
    final name = p.basename(path).trim().isEmpty
        ? 'attachment-${index + 1}'
        : p.basename(path).trim();
    final id = 'attachment-${index + 1}-${_randomSuffix()}';
    AgentFeedAttachment rejected(String errorCode, {int byteLength = 0}) {
      return AgentFeedAttachment(
        id: id,
        name: name,
        mediaType: lookupMimeType(path) ?? 'application/octet-stream',
        encoding: '',
        byteLength: byteLength,
        privacy: 'explicit-user-selection',
        transfer: AgentFeedAttachmentTransfer.rejected,
        errorCode: errorCode,
      );
    }

    final file = File(path);
    try {
      final stat = await file.stat();
      if (stat.type != FileSystemEntityType.file) {
        return rejected('file_not_found');
      }
      if (stat.size > _maxFeedAttachmentBytes) {
        return rejected('attachment_too_large', byteLength: stat.size);
      }
      if (stat.size > remainingBytes) {
        return rejected('attachment_total_too_large', byteLength: stat.size);
      }
      RandomAccessFile? reader;
      late Uint8List bytes;
      try {
        reader = await file.open(mode: FileMode.read);
        bytes = await reader.read(_maxFeedAttachmentBytes + 1);
      } finally {
        await reader?.close();
      }
      if (bytes.length > _maxFeedAttachmentBytes || bytes.length != stat.size) {
        return rejected(
          'attachment_changed_during_read',
          byteLength: bytes.length,
        );
      }
      final mediaType =
          lookupMimeType(
            path,
            headerBytes: bytes.take(512).toList(growable: false),
          ) ??
          'application/octet-stream';
      if (!_feedAttachmentIsUtf8Text(mediaType)) {
        return AgentFeedAttachment(
          id: id,
          name: name,
          mediaType: mediaType,
          encoding: 'binary',
          byteLength: bytes.length,
          privacy: 'explicit-user-selection',
          transfer: AgentFeedAttachmentTransfer.rejected,
          errorCode: 'binary_attachment_not_supported',
        );
      }
      try {
        return AgentFeedAttachment(
          id: id,
          name: name,
          mediaType: mediaType,
          encoding: 'utf-8',
          byteLength: bytes.length,
          privacy: 'explicit-user-selection',
          transfer: AgentFeedAttachmentTransfer.inlineText,
          content: utf8.decode(bytes, allowMalformed: false),
        );
      } on FormatException {
        return rejected('attachment_invalid_utf8', byteLength: bytes.length);
      }
    } on FileSystemException {
      return rejected('file_not_found');
    }
  }

  bool _feedAttachmentIsUtf8Text(String mediaType) {
    return mediaType.startsWith('text/') ||
        const {
          'application/json',
          'application/ld+json',
          'application/xml',
          'application/yaml',
          'application/x-yaml',
        }.contains(mediaType);
  }

  AgentFeedTimeline _refreshFeedPostsForAgentId(
    String agentId,
    List<AgentConversationSession> sessions,
    AgentFeedTimeline timeline,
  ) {
    if (sessions.isEmpty) {
      return timeline;
    }
    final ranked = List<AgentConversationSession>.from(sessions)
      ..sort((a, b) {
        final aUpdated = _parseIso(a.updatedAt);
        final bUpdated = _parseIso(b.updatedAt);
        if (aUpdated == null && bUpdated == null) {
          return 0;
        }
        if (aUpdated == null) {
          return 1;
        }
        if (bUpdated == null) {
          return -1;
        }
        return bUpdated.compareTo(aUpdated);
      });
    final bounded = ranked
        .take(_maxFeedSessionsPerAgent)
        .toList(growable: false);
    var nextTimeline = timeline;
    for (final session in bounded) {
      nextTimeline = _upsertFeedPostForSession(agentId, session, nextTimeline);
    }
    return nextTimeline;
  }

  AgentFeedTimeline _upsertFeedPostForSession(
    String agentId,
    AgentConversationSession session,
    AgentFeedTimeline timeline,
  ) {
    final postId = _feedPostIdForSession(agentId, session.id);
    final existingIndex = timeline.posts.indexWhere((p) => p.id == postId);
    final existing = existingIndex >= 0 ? timeline.posts[existingIndex] : null;

    final updatedAt = _parseIso(session.updatedAt) ?? DateTime.now().toUtc();
    final createdAt =
        existing?.createdAt ??
        (session.createdAt.isNotEmpty
            ? session.createdAt
            : updatedAt.toIso8601String());

    final author = _feedAuthorForAgent(agentId);
    final title = session.title.trim().isNotEmpty
        ? session.title
        : '${author.displayName} 完成了一项工作';
    final body = session.preview.trim().isNotEmpty
        ? session.preview
        : _lastAssistantText(session.messages);
    final status = _feedStatusForSession(session);
    final metrics = AgentFeedMetrics(
      durationMillis: _estimateSessionDurationMillis(session),
      stepCount: session.messageCount,
      tokenCount: _estimateTokenCount(session.messages),
      issueCount: _countIssues(session.messages),
    );

    final post = AgentFeedPost(
      id: postId,
      author: author,
      createdAt: createdAt,
      updatedAt: updatedAt.toIso8601String(),
      title: title,
      body: body,
      sourceAgentId: agentId,
      sourceSessionId: session.id,
      status: status,
      metrics: metrics,
      commentIds: existing?.commentIds ?? const [],
      repostIds: existing?.repostIds ?? const [],
      reactionCounts: existing?.reactionCounts ?? const {},
    );

    if (existing != null && _feedPostContentEqual(existing, post)) {
      return timeline;
    }

    final posts = List<AgentFeedPost>.from(timeline.posts, growable: true);
    if (existingIndex >= 0) {
      posts[existingIndex] = post;
    } else {
      posts.add(post);
    }
    return timeline.copyWith(posts: posts);
  }

  String _userFeedPostTitle(String body, List<String> mentionIds) {
    final labels = mentionIds
        .map((id) {
          final target = scannedTargets
              .where((t) => t.target == id)
              .firstOrNull;
          if (target != null) {
            return target.label.trim().isNotEmpty
                ? target.label
                : target.target;
          }
          return id;
        })
        .join(', ');
    return '@$labels $body';
  }

  String _stripMentionTokens(String text) {
    return text
        .replaceAll(RegExp(r'@\S+'), '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  Future<void> addFeedComment(
    String postId,
    String text, {
    String? replyToCommentId,
  }) async {
    final normalized = text.trim();
    if (normalized.isEmpty) {
      return;
    }
    final post = _feedPostById(postId);
    if (post == null) {
      return;
    }
    final now = DateTime.now().toUtc().toIso8601String();
    final comment = AgentFeedComment(
      id: 'comment-$now-${_randomSuffix()}',
      postId: postId,
      author: _currentUserFeedAuthor(),
      createdAt: now,
      text: normalized,
      replyToCommentId: replyToCommentId?.trim().isNotEmpty == true
          ? replyToCommentId
          : null,
    );
    final comments = List<AgentFeedComment>.from(
      feedTimeline.comments,
      growable: true,
    )..add(comment);
    final postComments = List<String>.from(post.commentIds, growable: true)
      ..add(comment.id);
    final posts = feedTimeline.posts
        .map((p) {
          return p.id == postId ? p.copyWith(commentIds: postComments) : p;
        })
        .toList(growable: false);

    feedTimeline = feedTimeline.copyWith(posts: posts, comments: comments);
    _notifyStateChanged();
    await saveFeedTimeline();

    // Treat the comment as user feedback to the originating agent.
    if (post.sourceAgentId.trim().isNotEmpty &&
        post.sourceSessionId.trim().isNotEmpty) {
      unawaited(
        _sendFeedbackToAgent(
          agentId: post.sourceAgentId,
          sessionId: post.sourceSessionId,
          text: normalized,
        ),
      );
    }
  }

  Future<void> repostFeedPost(
    String postId,
    String toAgentId, {
    String? note,
  }) async {
    final post = _feedPostById(postId);
    if (post == null || toAgentId.trim().isEmpty) {
      return;
    }
    final target = scannedTargets
        .where((t) => t.target == toAgentId)
        .firstOrNull;
    final account = mobileAgentAccounts
        .where((a) => a.id == toAgentId)
        .firstOrNull;
    final toName = target?.label ?? account?.label ?? toAgentId;
    final now = DateTime.now().toUtc().toIso8601String();
    final repost = AgentFeedRepost(
      id: 'repost-$now-${_randomSuffix()}',
      postId: postId,
      fromAuthor: _currentUserFeedAuthor(),
      toAgentId: toAgentId,
      toAgentName: toName,
      createdAt: now,
      note: note?.trim() ?? '',
    );
    final reposts = List<AgentFeedRepost>.from(
      feedTimeline.reposts,
      growable: true,
    )..add(repost);
    final postReposts = List<String>.from(post.repostIds, growable: true)
      ..add(repost.id);
    final posts = feedTimeline.posts
        .map((p) {
          return p.id == postId ? p.copyWith(repostIds: postReposts) : p;
        })
        .toList(growable: false);

    feedTimeline = feedTimeline.copyWith(posts: posts, reposts: reposts);
    _notifyStateChanged();
    await saveFeedTimeline();

    // Hand the work off to the target agent by sending a synthesized message.
    final handoffText = _buildHandoffText(post, note);
    if (target != null) {
      unawaited(
        _sendFeedbackToAgent(
          agentId: target.target,
          sessionId: '',
          text: handoffText,
        ),
      );
    } else if (account != null) {
      unawaited(startMobileProviderConversation(account));
    }
  }

  Future<void> toggleFollowAuthor(AgentFeedAuthor author) async {
    final normalized = author.id.trim();
    if (normalized.isEmpty) {
      return;
    }
    final existingIndex = feedTimeline.following.indexWhere(
      (f) => f.author.id == normalized,
    );
    List<AgentFeedFollowing> following;
    if (existingIndex >= 0) {
      following = List<AgentFeedFollowing>.from(feedTimeline.following)
        ..removeAt(existingIndex);
    } else {
      final now = DateTime.now().toUtc().toIso8601String();
      following = List<AgentFeedFollowing>.from(feedTimeline.following)
        ..add(
          AgentFeedFollowing(
            id: 'following-$now-${_randomSuffix()}',
            author: author,
            followedAt: now,
          ),
        );
    }
    feedTimeline = feedTimeline.copyWith(following: following);
    _notifyStateChanged();
    await saveFeedTimeline();
  }

  Future<void> deleteFeedPost(String postId) async {
    final deletedPost = _feedPostById(postId);
    final posts = feedTimeline.posts
        .where((p) => p.id != postId)
        .toList(growable: false);
    if (posts.length == feedTimeline.posts.length) {
      return;
    }
    final comments = feedTimeline.comments
        .where((c) => c.postId != postId)
        .toList(growable: false);
    final reposts = feedTimeline.reposts
        .where((r) => r.postId != postId)
        .toList(growable: false);
    feedTimeline = feedTimeline.copyWith(
      posts: posts,
      dispatchOutcomes: deletedPost == null
          ? feedTimeline.dispatchOutcomes
          : feedTimeline.dispatchOutcomes
                .where(
                  (outcome) => outcome.dispatchId != deletedPost.dispatchId,
                )
                .toList(growable: false),
      comments: comments,
      reposts: reposts,
    );
    _notifyStateChanged();
    await saveFeedTimeline();
  }

  AgentFeedPost? _feedPostById(String postId) {
    for (final post in feedTimeline.posts) {
      if (post.id == postId) {
        return post;
      }
    }
    return null;
  }

  List<AgentFeedDispatchOutcome> feedDispatchOutcomesForPost(String postId) {
    final post = _feedPostById(postId);
    if (post == null || post.dispatchId.trim().isEmpty) {
      return const [];
    }
    return List.unmodifiable(
      feedTimeline.dispatchOutcomes.where(
        (outcome) => outcome.dispatchId == post.dispatchId,
      ),
    );
  }

  Future<bool> retryFeedDispatch(String postId, String targetId) {
    return _dispatchFeedTarget(postId, targetId);
  }

  Future<bool> cancelFeedDispatch(String postId, String targetId) async {
    final post = _feedPostById(postId);
    if (post == null) {
      return false;
    }
    final outcome = _feedDispatchOutcome(post.dispatchId, targetId);
    if (outcome == null ||
        (outcome.status != AgentFeedDispatchStatus.pending &&
            outcome.status != AgentFeedDispatchStatus.retryable)) {
      return false;
    }
    await _replaceFeedDispatchOutcome(
      outcome.copyWith(
        status: AgentFeedDispatchStatus.failed,
        updatedAt: DateTime.now().toUtc().toIso8601String(),
        errorCode: 'dispatch_cancelled',
      ),
    );
    return true;
  }

  AgentFeedDispatchOutcome? _feedDispatchOutcome(
    String dispatchId,
    String targetId,
  ) {
    final normalizedTarget = targetId.trim();
    for (final outcome in feedTimeline.dispatchOutcomes) {
      if (outcome.dispatchId == dispatchId &&
          outcome.targetId == normalizedTarget) {
        return outcome;
      }
    }
    return null;
  }

  Future<bool> _dispatchFeedTarget(String postId, String targetId) async {
    final post = _feedPostById(postId);
    if (post == null) {
      return false;
    }
    final existing = _feedDispatchOutcome(post.dispatchId, targetId);
    if (existing == null ||
        (existing.status != AgentFeedDispatchStatus.pending &&
            existing.status != AgentFeedDispatchStatus.retryable)) {
      return false;
    }
    if (existing.attemptCount >= _maxFeedDispatchAttempts) {
      await _replaceFeedDispatchOutcome(
        existing.copyWith(
          status: AgentFeedDispatchStatus.failed,
          updatedAt: DateTime.now().toUtc().toIso8601String(),
          errorCode: 'dispatch_attempt_limit_reached',
        ),
      );
      return false;
    }

    final running = existing.copyWith(
      status: AgentFeedDispatchStatus.running,
      attemptCount: existing.attemptCount + 1,
      updatedAt: DateTime.now().toUtc().toIso8601String(),
      errorCode: '',
    );
    await _replaceFeedDispatchOutcome(running);
    final delivery = await _deliverAgentText(
      agentId: running.targetId,
      sessionId: '',
      text: post.dispatchText.trim().isEmpty ? post.body : post.dispatchText,
    );
    final status = delivery.succeeded
        ? AgentFeedDispatchStatus.succeeded
        : delivery.retryable && running.attemptCount < _maxFeedDispatchAttempts
        ? AgentFeedDispatchStatus.retryable
        : AgentFeedDispatchStatus.failed;
    await _replaceFeedDispatchOutcome(
      running.copyWith(
        status: status,
        updatedAt: DateTime.now().toUtc().toIso8601String(),
        errorCode: delivery.errorCode,
      ),
    );
    return delivery.succeeded;
  }

  Future<void> _replaceFeedDispatchOutcome(
    AgentFeedDispatchOutcome replacement,
  ) async {
    final outcomes = List<AgentFeedDispatchOutcome>.from(
      feedTimeline.dispatchOutcomes,
      growable: true,
    );
    final index = outcomes.indexWhere(
      (outcome) => outcome.key == replacement.key,
    );
    if (index < 0) {
      return;
    }
    outcomes[index] = replacement;
    final posts = [
      for (final post in feedTimeline.posts)
        if (post.dispatchId == replacement.dispatchId)
          post.copyWith(
            status: deriveAgentFeedPostStatus(post, outcomes),
            updatedAt: replacement.updatedAt,
          )
        else
          post,
    ];
    feedTimeline = feedTimeline.copyWith(
      posts: posts,
      dispatchOutcomes: List.unmodifiable(outcomes),
    );
    _notifyStateChanged();
    await saveFeedTimeline();
  }

  Future<void> _sendFeedbackToAgent({
    required String agentId,
    required String sessionId,
    required String text,
  }) async {
    final delivery = await _deliverAgentText(
      agentId: agentId,
      sessionId: sessionId,
      text: text,
    );
    if (!delivery.succeeded) {
      throw StateError(delivery.errorCode);
    }
  }

  Future<({bool succeeded, bool retryable, String errorCode})>
  _deliverAgentText({
    required String agentId,
    required String sessionId,
    required String text,
  }) async {
    final normalizedAgent = agentId.trim();
    if (normalizedAgent.isEmpty) {
      return (
        succeeded: false,
        retryable: false,
        errorCode: 'dispatch_target_empty',
      );
    }
    if (_activeSendTargets.contains(normalizedAgent)) {
      return (
        succeeded: false,
        retryable: true,
        errorCode: 'dispatch_target_busy',
      );
    }
    _activeSendTargets.add(normalizedAgent);
    try {
      if (isAgentOrchestrationTargetId(normalizedAgent)) {
        if (!routingModuleAvailable) {
          return (
            succeeded: false,
            retryable: false,
            errorCode: 'routing_module_unavailable',
          );
        }
        final savedAgentId = selectedConversationAgentId;
        final savedSessionId = selectedConversationSessionId;
        final savedPreparing = _preparingNewConversation;
        try {
          selectedConversationAgentId = agentOrchestrationTargetId;
          selectedConversationSessionId = sessionId;
          _preparingNewConversation = sessionId.trim().isEmpty;
          lastError = '';
          await _sendOrchestratedConversationMessage(text);
          final errorCode = lastError.trim();
          return errorCode.isEmpty
              ? (succeeded: true, retryable: false, errorCode: '')
              : (
                  succeeded: false,
                  retryable: _feedDispatchErrorIsRetryable(errorCode),
                  errorCode: errorCode,
                );
        } finally {
          selectedConversationAgentId = savedAgentId;
          selectedConversationSessionId = savedSessionId;
          _preparingNewConversation = savedPreparing;
        }
      }
      final target = scannedTargets
          .where((candidate) => candidate.target == normalizedAgent)
          .firstOrNull;
      if (target == null) {
        return (
          succeeded: false,
          retryable: false,
          errorCode: 'dispatch_target_not_found',
        );
      }
      if (!target.canRelayRuntime) {
        return (
          succeeded: false,
          retryable: false,
          errorCode: target.conversationSendGateReason,
        );
      }
      final turn = await conversationService.send(
        runner: agentService,
        agentId: target.target,
        text: text,
        sessionId: sessionId.trim(),
        bind: AgentDispatchBind(binaryPath: target.binaryPath ?? ''),
        conversationReadiness: target.conversationReadiness,
      );
      if (turn.ok) {
        return (succeeded: true, retryable: false, errorCode: '');
      }
      final errorCode = turn.errorCode.trim().isEmpty
          ? _runtimeAdapterErrorCode(turn.raw)
          : turn.errorCode.trim();
      return (
        succeeded: false,
        retryable: _feedDispatchErrorIsRetryable(errorCode),
        errorCode: errorCode,
      );
    } catch (_) {
      return (
        succeeded: false,
        retryable: true,
        errorCode: 'feed_dispatch_transport_failed',
      );
    } finally {
      _activeSendTargets.remove(normalizedAgent);
    }
  }

  bool _feedDispatchErrorIsRetryable(String errorCode) {
    return const {
      'dispatch_stream_incomplete',
      'dispatch_target_busy',
      'feed_dispatch_transport_failed',
      'native_agent_timeout',
      'native_agent_transport_failed',
      'secure_relay_result_fetch_failed',
      'secure_relay_result_timeout',
    }.contains(errorCode);
  }

  AgentFeedAuthor _feedAuthorForAgent(String agentId) {
    final target = scannedTargets.where((t) => t.target == agentId).firstOrNull;
    if (target != null) {
      return AgentFeedAuthor(
        id: 'target:${target.target}',
        displayName: target.label.trim().isNotEmpty
            ? target.label
            : target.target,
        isAgent: true,
        targetId: target.target,
      );
    }
    final account = mobileAgentAccounts
        .where((a) => a.id == agentId)
        .firstOrNull;
    if (account != null) {
      return AgentFeedAuthor(
        id: 'account:${account.id}',
        displayName: account.label.trim().isNotEmpty
            ? account.label
            : account.provider.label,
        isAgent: true,
        accountId: account.provider.id,
      );
    }
    return AgentFeedAuthor(
      id: 'agent:$agentId',
      displayName: agentId,
      isAgent: true,
    );
  }

  AgentFeedAuthor _currentUserFeedAuthor() {
    return const AgentFeedAuthor(
      id: 'user:local',
      displayName: '我',
      isAgent: false,
    );
  }

  String _buildHandoffText(AgentFeedPost post, String? note) {
    final buffer = StringBuffer();
    buffer.writeln('接手来自 ${post.author.displayName} 的工作：');
    buffer.writeln('标题：${post.title}');
    if (post.body.trim().isNotEmpty) {
      buffer.writeln('内容：${post.body.trim()}');
    }
    if (note != null && note.trim().isNotEmpty) {
      buffer.writeln('备注：${note.trim()}');
    }
    return buffer.toString().trim();
  }

  String _feedPostIdForSession(String agentId, String sessionId) {
    return 'post:$agentId:$sessionId';
  }

  AgentFeedPostStatus _feedStatusForSession(AgentConversationSession session) {
    if (session.messages.isEmpty) {
      return AgentFeedPostStatus.working;
    }
    final last = session.messages.last;
    if (last.kind == AgentConversationMessageKind.error) {
      return AgentFeedPostStatus.error;
    }
    if (last.role == 'assistant' || last.role == 'model') {
      return AgentFeedPostStatus.done;
    }
    return AgentFeedPostStatus.working;
  }

  int _estimateSessionDurationMillis(AgentConversationSession session) {
    final created = _parseIso(session.createdAt);
    final updated = _parseIso(session.updatedAt);
    if (created == null || updated == null) {
      return 0;
    }
    return updated.difference(created).inMilliseconds.abs();
  }

  int _estimateTokenCount(List<AgentConversationMessage> messages) {
    var count = 0;
    for (final message in messages) {
      count += (message.text.length / 4).ceil();
    }
    return count;
  }

  int _countIssues(List<AgentConversationMessage> messages) {
    var count = 0;
    for (final message in messages) {
      if (message.kind == AgentConversationMessageKind.error) {
        count += 1;
      }
    }
    return count;
  }

  String _lastAssistantText(List<AgentConversationMessage> messages) {
    for (var i = messages.length - 1; i >= 0; i--) {
      final message = messages[i];
      if (message.role == 'assistant' || message.role == 'model') {
        return message.text.trim();
      }
    }
    return '';
  }

  bool _feedPostContentEqual(AgentFeedPost a, AgentFeedPost b) {
    return a.title == b.title &&
        a.body == b.body &&
        a.status == b.status &&
        a.updatedAt == b.updatedAt &&
        a.metrics.durationMillis == b.metrics.durationMillis &&
        a.metrics.stepCount == b.metrics.stepCount &&
        a.metrics.issueCount == b.metrics.issueCount;
  }

  DateTime? _parseIso(String value) {
    return DateTime.tryParse(value);
  }

  String _randomSuffix() {
    return '${DateTime.now().toUtc().microsecondsSinceEpoch}';
  }
}
