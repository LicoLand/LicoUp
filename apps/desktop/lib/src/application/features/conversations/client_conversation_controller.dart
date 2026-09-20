import 'dart:async';
import 'dart:convert';

import 'package:licoup/src/application/state/application_signal.dart';

import 'package:licoup/src/backend/features/conversations/services/client_conversation_service.dart';
import 'package:licoup/src/application/features/conversations/client_conversation_recent_participants.dart';
import 'package:licoup/src/application/features/conversations/client_memory_diagnostic_journal.dart';
import 'package:licoup/src/contracts/conversation_native_port.dart';
import 'package:licoup/src/contracts/client_memory_diagnostics.dart';
import 'package:licoup/src/contracts/agent_conversation_attachment.dart';
import 'package:licoup/src/contracts/client_conversation_models.dart';
import 'package:licoup/src/contracts/generated/conversation.g.dart';
import 'package:licoup/src/contracts/problem_codes/problem_codes.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/platform/native_client/native_rpc_priority.dart';

final class ClientConversationController extends ApplicationStateOwner {
  ClientConversationController({
    required ClientConversationNativePort native,
    ClientConversationService? service,
    void Function(String conversationId)? onSelectionChanged,
    void Function(ClientConversation conversation)? onSnapshotApplied,
    bool Function(Map<String, dynamic> notice)? completionNoticePublisher,
    ClientMemoryDiagnosticJournal? memoryJournal,
    Duration? pendingNoticePollInterval,
    Duration? activityEchoInterval,
  }) : _service = service ?? ClientConversationService(native: native),
       _onSelectionChanged = onSelectionChanged,
       _onSnapshotApplied = onSnapshotApplied,
       _completionNoticePublisher = completionNoticePublisher,
       _memoryJournal = memoryJournal,
       _pendingNoticePollInterval =
           pendingNoticePollInterval ?? defaultPendingNoticePollInterval,
       _activityEchoInterval =
           activityEchoInterval ?? defaultActivityEchoInterval;

  /// Matches [ConversationRefreshPolicy.backgroundInterval] for idle surfaces.
  static const Duration defaultPendingNoticePollInterval = Duration(
    seconds: 30,
  );

  /// The activity echo reads the selected conversation, so it runs on its own
  /// timer. The notice poll has a narrower contract — it may only ask for
  /// pending notices — and folding a transcript read into it would break that.
  static const Duration defaultActivityEchoInterval = Duration(seconds: 30);

  final ClientConversationService _service;
  final void Function(String conversationId)? _onSelectionChanged;
  final void Function(ClientConversation conversation)? _onSnapshotApplied;
  final bool Function(Map<String, dynamic> notice)? _completionNoticePublisher;
  final ClientMemoryDiagnosticJournal? _memoryJournal;
  final Duration _pendingNoticePollInterval;
  final Duration _activityEchoInterval;
  Timer? _pendingNoticeTimer;
  Timer? _activityEchoTimer;
  Future<void>? _pendingNoticePoll;
  Future<void>? _selectedActivityPoll;
  bool _flushingCompletionNoticeAcks = false;
  final Set<String> _pendingAckNotificationIds = <String>{};

  bool _initialized = false;
  bool _disposed = false;
  Future<void>? _initialization;
  bool _loading = false;
  Completer<void>? _loadingCompletion;
  bool _sending = false;
  String _selectedConversationId = '';
  String _draft = '';
  String _failureStage = '';
  String _failureCode = '';
  String _failureConversationId = '';
  String _failureComponent = '';
  bool? _failureRetryable;
  String _failureRecovery = '';
  String _failureRef = '';
  String _failureOccurredAt = '';
  String _failureStrategyCode = '';
  var _failureSeq = 0;
  List<Map<String, dynamic>> _liveTurns = const [];
  bool _dispatchPending = false;
  List<ClientConversationSummary> _summaries = const [];
  List<ClientConversationSummary> _archivedSummaries = const [];
  ClientConversation? _selectedConversation;
  List<ClientConversationEvent> _events = const [];
  final Map<String, _CachedClientConversation> _conversationCache = {};
  static const int _eventPageSize = 20;
  final Set<String> _loadingEarlierConversations = {};
  final Map<String, String> _earlierPageErrors = {};
  final Map<String, int> _historyGenerations = {};
  final Map<String, int> _latestReadVersions = {};
  final ClientConversationRecentParticipants _recentParticipants =
      ClientConversationRecentParticipants();
  List<String> _availableConversationAgentIds = const [];
  bool _memoryConversationOpen = false;
  int _memoryLiveTurnCount = 0;

  bool get loading => _loading;
  bool get sending => _sending;
  String get selectedConversationId => _selectedConversationId;
  String get draft => _draft;
  String get failureStage => _failureStage;
  String get failureCode => _failureCode;

  /// The Conversation one in-flight failure belongs to. Empty means the
  /// failure is not conversation-scoped (for example a catalog read); scoped
  /// failures must not paint over a different Conversation after a selection
  /// change.
  String get failureConversationId => _failureConversationId;
  String get failureComponent => _failureComponent;
  bool? get failureRetryable => _failureRetryable;
  String get failureRecovery => _failureRecovery;
  String get failureRef => _failureRef;
  String get failureProblemCode => ProblemCodeCopy.problemCode(_failureCode);
  String get failureCopyBlob => ProblemCodeCopy.copyableDetail(
    legacyCode: _failureCode,
    stage: _failureStage,
    occurrenceId: _failureRef,
    occurredAt: _failureOccurredAt,
    strategyCode: _failureStrategyCode,
    component: _failureComponent,
    retryable: _failureRetryable,
    recovery: _failureRecovery,
  );

  List<Map<String, dynamic>> get liveTurns => _liveTurns;
  bool get dispatchPending => _dispatchPending;

  /// Drops the composer busy latch once no Membership turn is live.
  ///
  /// `after-post` sets [dispatchPending] when it returns a handle. Completing
  /// that turn does not go back through send, so the pane must settle it.
  void settleLiveDispatch() {
    if (_disposed || (!_dispatchPending && _liveTurns.isEmpty)) return;
    _liveTurns = const [];
    _dispatchPending = false;
    _publishChange();
  }

  ClientConversation? get selectedConversation => _selectedConversation;
  List<ClientConversationEvent> get events => _events;
  bool get hasEarlierEvents =>
      _conversationCache[_selectedConversationId]?.hasEarlier ?? false;
  bool get loadingEarlierEvents =>
      _loadingEarlierConversations.contains(_selectedConversationId);
  String get earlierEventsError =>
      _earlierPageErrors[_selectedConversationId] ?? '';
  List<String> get recentParticipantAgentIds => _recentParticipants.agentIds;
  List<ClientConversationSummary> get archivedConversations =>
      _archivedSummaries;

  /// Surfaces a group-operation failure on the conversation banner.
  ///
  /// [conversationId] pins the failure to the Conversation that originated
  /// the operation; when empty, the Conversation selected at call time owns
  /// it. An empty selection leaves the failure unscoped.
  void surfaceFailure(
    String stage,
    String code, {
    String conversationId = '',
    String component = '',
    bool? retryable,
    String recovery = '',
  }) {
    if (_disposed) return;
    final nextStage = stage.trim();
    final nextCode = code.trim();
    if (nextStage.isEmpty || nextCode.isEmpty) return;
    final scopedId = conversationId.trim();
    _recordFailure(
      nextStage,
      nextCode,
      conversationId: scopedId.isEmpty ? _selectedConversationId : scopedId,
      component: component,
      retryable: retryable,
      recovery: recovery,
    );
    _publishChange();
  }

  void _clearFailure() {
    _failureStage = '';
    _failureCode = '';
    _failureConversationId = '';
    _failureComponent = '';
    _failureRetryable = null;
    _failureRecovery = '';
    _failureRef = '';
    _failureOccurredAt = '';
    _failureStrategyCode = '';
  }

  void _recordFailure(
    String stage,
    String code, {
    String conversationId = '',
    String strategyCode = '',
    String component = '',
    bool? retryable,
    String recovery = '',
  }) {
    _failureStage = stage;
    _failureCode = code;
    _failureConversationId = conversationId.trim();
    _failureStrategyCode = strategyCode;
    _failureComponent = component.trim();
    _failureRetryable = retryable;
    _failureRecovery = recovery.trim();
    _failureOccurredAt = DateTime.now().toUtc().toIso8601String();
    _failureSeq = (_failureSeq + 1) & 0xFFFF;
    final mixed =
        (DateTime.now().microsecondsSinceEpoch ^ (_failureSeq << 8)) & 0xFFFF;
    _failureRef = '#L-${mixed.toRadixString(16).toUpperCase().padLeft(4, '0')}';
  }

  List<Map<String, dynamic>> _selectedTaskViews =
      const <Map<String, dynamic>>[];
  final Set<String> _publishedCompletionIds = <String>{};
  List<Map<String, dynamic>> _freshCompletionNotices =
      const <Map<String, dynamic>>[];

  List<Map<String, dynamic>> get selectedTaskViews => _selectedTaskViews;

  /// Drains freshly polled completion notices to the wired Application-level
  /// publisher and acknowledges the ones it accepted. Publication is a
  /// notification side effect owned here, not by any projection producer; an
  /// unpublished notice stays unacknowledged so the next poll retries it.
  void _publishFreshCompletionNotices() {
    final publisher = _completionNoticePublisher;
    if (publisher == null || _freshCompletionNotices.isEmpty) return;
    final notices = _freshCompletionNotices;
    _freshCompletionNotices = const <Map<String, dynamic>>[];
    final published = <String>[];
    for (final notice in notices) {
      final id = (notice['notificationId'] ?? '').toString().trim();
      if (id.isEmpty) continue;
      try {
        if (publisher(notice)) published.add(id);
      } on Object {
        continue;
      }
    }
    if (published.isNotEmpty) {
      acknowledgePublishedCompletionNotices(published);
    }
  }

  List<ClientConversationSummary> get groupConversations {
    final childrenByParent = <String, List<ClientConversationSummary>>{};
    for (final summary in _summaries) {
      final parent = summary.parentConversationId;
      if (parent != null && parent.isNotEmpty) {
        childrenByParent
            .putIfAbsent(parent, () => <ClientConversationSummary>[])
            .add(summary);
      }
    }
    final archivedByParent = <String, List<ClientConversationSummary>>{};
    for (final summary in _archivedSummaries) {
      final parent = summary.parentConversationId;
      if (parent != null && parent.isNotEmpty) {
        archivedByParent
            .putIfAbsent(parent, () => <ClientConversationSummary>[])
            .add(summary);
      }
    }
    return _summaries
        .where(
          (conversation) =>
              conversation.isGroup && !conversation.isContinuityChild,
        )
        .map(
          (root) => root
              .withChildren(childrenByParent[root.id] ?? const [])
              .withArchivedChildren(archivedByParent[root.id] ?? const []),
        )
        .toList(growable: false);
  }

  Future<void> executeContinuityCommand({
    required String conversationId,
    required ContinuityCommand command,
    required String goalId,
    Map<String, dynamic>? extra,
  }) async {
    if (_disposed || command == ContinuityCommand.unrecognized) return;
    final payload = <String, dynamic>{
      'action': command.wireName,
      'conversationId': conversationId,
      'goalId': goalId,
      ...?extra,
    };
    await _service.execute(payload);
    await reloadSelected();
  }

  Future<void> activateCompletionNotice({
    required String notificationId,
  }) async {
    if (_disposed) return;
    final id = notificationId.trim();
    if (id.isEmpty) return;
    final anchor = _selectedConversation;
    final owner = anchor?.localOwnerMembership;
    if (anchor == null || owner == null) return;
    try {
      final raw = _objectMap(
        await _service.execute({
          'action': 'resolve-completion-notice',
          'conversationId': anchor.id,
          'ownerMembershipId': owner.id,
          'notificationId': id,
        }),
      );
      if (raw['ok'] != true) return;
      if (_disposed) return;
      final child = (raw['childConversationId'] ?? '').toString().trim();
      if (child.isEmpty) return;
      if (_selectedConversationId != child) {
        await selectConversation(child);
      } else {
        await reloadSelected();
      }
    } on ClientConversationServiceFailure {
      return;
    }
  }

  void acknowledgePublishedCompletionNotices(Iterable<String> ids) {
    if (_disposed) return;
    var pendingAck = false;
    for (final id in ids) {
      final notificationId = id.trim();
      if (notificationId.isEmpty) continue;
      _publishedCompletionIds.add(notificationId);
      if (_pendingAckNotificationIds.add(notificationId)) {
        pendingAck = true;
      }
    }
    if (pendingAck) {
      unawaited(_flushCompletionNoticeAcks());
    }
  }

  void _queueCompletionNotice(Map<String, dynamic> notice) {
    final notificationId = (notice['notificationId'] ?? '').toString().trim();
    if (notificationId.isEmpty ||
        _publishedCompletionIds.contains(notificationId) ||
        _freshCompletionNotices.any(
          (item) =>
              (item['notificationId'] ?? '').toString().trim() ==
              notificationId,
        )) {
      return;
    }
    _freshCompletionNotices = [..._freshCompletionNotices, notice];
  }

  void _startPendingNoticePoll() {
    _pendingNoticeTimer?.cancel();
    if (_disposed) return;
    _pendingNoticeTimer = Timer.periodic(_pendingNoticePollInterval, (_) {
      unawaited(pollPendingCompletionNotices());
    });
    unawaited(pollPendingCompletionNotices());
  }

  void _startActivityEchoPoll() {
    _activityEchoTimer?.cancel();
    if (_disposed) return;
    _activityEchoTimer = Timer.periodic(_activityEchoInterval, (_) {
      unawaited(pollSelectedConversationActivity());
    });
    unawaited(pollSelectedConversationActivity());
  }

  /// Picks up events another actor appended to the selected conversation.
  ///
  /// Work can reach a conversation without this client asking: an external
  /// dispatch, a peer client, a subagent, or a settling Flywheel step. Every
  /// reload path is otherwise user-driven, so such events stayed invisible
  /// until the next interaction — the conversation looked stalled while an
  /// Agent was in fact working in it.
  Future<void> pollSelectedConversationActivity() async {
    if (_disposed || _selectedActivityPoll != null) return;
    final future = _pollSelectedConversationActivityOnce();
    _selectedActivityPoll = future;
    try {
      await future;
    } finally {
      if (identical(_selectedActivityPoll, future)) {
        _selectedActivityPoll = null;
      }
    }
  }

  Future<void> _pollSelectedConversationActivityOnce() async {
    final id = _selectedConversationId;
    if (_loading || id.isEmpty) return;
    final cached = _conversationCache[id];
    if (cached == null) return;
    final Map<String, dynamic> latest;
    try {
      latest = _objectMap(
        await _service.execute({
          'action': 'conversation.get',
          'conversationId': id,
          'includeNativeSessionReferences': true,
        }),
      );
    } on ClientConversationServiceFailure {
      return;
    }
    if (_disposed || _loading || _selectedConversationId != id) return;
    // The read is cheap; the reload is not. Only a real append justifies it,
    // and the resulting change also re-syncs the live turn observers, which is
    // what carries an Agent's in-flight output to the surface.
    final observed = ClientConversation.fromJson(latest);
    if (observed.revision == cached.conversation.revision &&
        observed.eventCount == cached.conversation.eventCount) {
      return;
    }
    // This snapshot is already the fresh record, so the transcript is read
    // against it directly instead of repeating the same `conversation.get`.
    try {
      await _applySelectedRaw(id, latest);
    } on ClientConversationServiceFailure {
      // A background reconcile must not raise an unhandled async error, and
      // must not paint a failure banner over work the user did not start. The
      // next tick retries on its own.
      return;
    }
    if (!_disposed) _publishChange();
  }

  /// Lifecycle-owned pending-notice poll. The initialize timer calls this;
  /// tests may await one tick without advancing the widget-test clock.
  Future<void> pollPendingCompletionNotices() async {
    if (_disposed || _pendingNoticePoll != null) return;
    final future = _pollPendingCompletionNoticesOnce();
    _pendingNoticePoll = future;
    try {
      await future;
    } finally {
      if (identical(_pendingNoticePoll, future)) {
        _pendingNoticePoll = null;
      }
    }
  }

  Future<void> _pollPendingCompletionNoticesOnce() async {
    await _flushCompletionNoticeAcks();
    if (_disposed) return;
    final selected = _selectedConversation;
    final owner = selected?.localOwnerMembership;
    if (selected == null || owner == null) return;
    try {
      final raw = _objectMap(
        await _service.execute({
          'action': 'list-pending-completion-notices',
          'conversationId': selected.id,
          'ownerMembershipId': owner.id,
        }),
      );
      if (_disposed) return;
      var queued = false;
      for (final notice in _maps(raw['pendingCompletionNotices'])) {
        final before = _freshCompletionNotices.length;
        _queueCompletionNotice(notice);
        queued = queued || _freshCompletionNotices.length > before;
      }
      _publishFreshCompletionNotices();
      if (queued) _publishChange();
    } on ClientConversationServiceFailure {
      return;
    }
  }

  Future<void> _flushCompletionNoticeAcks() async {
    if (_disposed ||
        _flushingCompletionNoticeAcks ||
        _pendingAckNotificationIds.isEmpty) {
      return;
    }
    final selected = _selectedConversation;
    final owner = selected?.localOwnerMembership;
    if (selected == null || owner == null) return;
    // The native command admits at most 50 IDs. Process each snapshot batch
    // once so denied IDs remain retryable without hiding later eligible IDs.
    final ids = _pendingAckNotificationIds.toList(growable: false);
    _flushingCompletionNoticeAcks = true;
    try {
      for (var start = 0; start < ids.length && !_disposed; start += 50) {
        final end = start + 50 < ids.length ? start + 50 : ids.length;
        final raw = _objectMap(
          await _service.execute({
            'action': 'ack-completion-notices',
            'conversationId': selected.id,
            'ownerMembershipId': owner.id,
            'notificationIds': ids.sublist(start, end),
          }),
        );
        if (_disposed) return;
        for (final id in _profileStringList(
          raw['acknowledgedNotificationIds'],
        )) {
          _pendingAckNotificationIds.remove(id);
        }
      }
    } on ClientConversationServiceFailure {
      return;
    } finally {
      _flushingCompletionNoticeAcks = false;
    }
  }

  Future<void> initialize() {
    if (_disposed || _initialized) return Future<void>.value();
    final active = _initialization;
    if (active != null) return active;
    final future = _initializeOnce();
    _initialization = future;
    return future;
  }

  Future<void> _initializeOnce() async {
    try {
      final succeeded = await _refresh(preloadLocal: true);
      if (!_disposed && succeeded) {
        _initialized = true;
        _startPendingNoticePoll();
        _startActivityEchoPoll();
      }
    } finally {
      _initialization = null;
    }
  }

  Future<void> refresh() async {
    await _refresh();
  }

  Future<bool> _refresh({bool preloadLocal = false}) => _guard(
    'list',
    conversationId: '',
    () async {
      await _refreshCatalogWithoutGuard();
      if (_disposed) return;
      var warmedLocal = false;
      // Local owns the first cold-start transcript read. Warm the same cache
      // used by selection before any Agent discovery/history lane can start;
      // preloading must never change the user's current conversation selection.
      if (preloadLocal &&
          _summaries.any(
            (item) => item.id == ClientConversation.defaultLocalAgentGroupId,
          ) &&
          !_conversationCache.containsKey(
            ClientConversation.defaultLocalAgentGroupId,
          )) {
        await _loadConversation(ClientConversation.defaultLocalAgentGroupId);
        warmedLocal = true;
      }
      if (_selectedConversationId.isNotEmpty &&
          !_isListedConversation(_selectedConversationId)) {
        _clearSelection();
      }
      if (_selectedConversationId.isNotEmpty &&
          !(warmedLocal &&
              _selectedConversationId ==
                  ClientConversation.defaultLocalAgentGroupId)) {
        await _loadSelected();
      }
    },
  );

  Future<void> selectConversation(String conversationId) async {
    final normalized = conversationId.trim();
    if (normalized.isEmpty) {
      clearSelection();
      return;
    }
    if (_disposed) return;
    if (_selectedConversationId == normalized &&
        _selectedConversation?.id == normalized) {
      return;
    }
    final changed = _selectedConversationId != normalized;
    if (changed) {
      _liveTurns = const [];
      _dispatchPending = false;
    }
    _selectedConversationId = normalized;
    _draft = '';
    final cached = _conversationCache[normalized];
    if (cached == null) {
      _selectedConversation = null;
      _events = const [];
      _recentParticipants.clear();
    } else {
      _selectedTaskViews = List<Map<String, dynamic>>.unmodifiable(
        cached.taskViews,
      );
      _applySelectedSnapshot(cached.conversation, cached.events);
    }
    if (changed) _onSelectionChanged?.call(normalized);
    _publishChange();
    if (cached == null) {
      try {
        await _loadSelected();
      } finally {
        _publishChange();
      }
    }
    unawaited(pollPendingCompletionNotices());
  }

  void clearSelection() {
    if (_selectedConversationId.isEmpty) return;
    _clearSelection();
    _publishChange();
  }

  void updateDraft(String value) {
    if (_draft == value) return;
    _draft = value;
    _publishChange();
  }

  /// Reconciles background Agent discovery without changing group membership.
  /// Newly discovered Agents join the Local roster at the queue tail.
  void syncAvailableConversationAgents(Iterable<TargetCandidate> targets) {
    final next = <String>[];
    final seen = <String>{};
    for (final target in targets) {
      final agentId = target.target.trim();
      if (target.isConversationAgent &&
          agentId.isNotEmpty &&
          seen.add(agentId)) {
        next.add(agentId);
      }
    }
    if (_sameStringList(_availableConversationAgentIds, next)) return;
    _availableConversationAgentIds = List<String>.unmodifiable(next);
    final conversation = _selectedConversation;
    if (conversation == null) return;
    final changed = _recentParticipants.applySnapshot(
      conversation: conversation,
      events: _events,
      availableLocalAgentIds: _availableConversationAgentIds,
    );
    if (changed) _publishChange();
  }

  /// A Local-roster Agent discovered after group creation becomes a durable
  /// member only after the user's explicit @ action.
  Future<bool> ensureSelectedAgentMembership({
    required String agentId,
    required String displayName,
  }) async {
    final normalizedAgentId = agentId.trim();
    final conversation = _selectedConversation;
    if (conversation == null || normalizedAgentId.isEmpty) return false;
    if (conversation.activeAgentMemberships.any(
      (membership) => membership.principal.agentId == normalizedAgentId,
    )) {
      return true;
    }
    await _waitUntilIdle();
    final selected = _selectedConversation;
    if (selected == null || selected.id != conversation.id) return false;
    if (selected.activeAgentMemberships.any(
      (membership) => membership.principal.agentId == normalizedAgentId,
    )) {
      return true;
    }
    return _guard('member-add', () async {
      await _service.execute({
        'action': 'conversation.membership.add',
        'conversationId': selected.id,
        'principal': {
          'id': 'agent:$normalizedAgentId',
          'kind': 'agent',
          'displayName': displayName.trim().isEmpty
              ? normalizedAgentId
              : displayName.trim(),
          'agentId': normalizedAgentId,
        },
        'access': 'member',
      });
      await _refreshCatalogWithoutGuard();
      await _loadSelected();
    });
  }

  /// Persists the explicitly selected strategy on the owning group
  /// Conversation. Passing null clears it; navigation never calls this path.
  Future<bool> setSelectedStrategyRevision(String? strategyRevision) async {
    final conversation = _selectedConversation;
    if (conversation == null || !conversation.group) return false;
    final normalized = strategyRevision?.trim() ?? '';
    if (conversation.strategyRevision == normalized) return true;
    await _waitUntilIdle();
    final selected = _selectedConversation;
    if (selected == null || !selected.group || selected.id != conversation.id) {
      return false;
    }
    if (selected.strategyRevision == normalized) return true;
    return _guard('strategy-set', () async {
      await _service.execute({
        'action': 'conversation.strategy.set',
        'conversationId': selected.id,
        'strategyRevision': normalized.isEmpty ? null : normalized,
      });
      await _refreshCatalogWithoutGuard();
      await _loadSelected();
    });
  }

  /// Designates the selected group's Assistant Membership. Passing null
  /// clears the designation; the ambiguous multi-Agent group stays
  /// undesignated until an explicit choice is made.
  Future<bool> setSelectedAssistantMembership(String? membershipId) async {
    final conversation = _selectedConversation;
    if (conversation == null || !conversation.group) return false;
    final normalized = membershipId?.trim() ?? '';
    if (conversation.assistantMembershipId == normalized) return true;
    await _waitUntilIdle();
    final selected = _selectedConversation;
    if (selected == null || !selected.group || selected.id != conversation.id) {
      return false;
    }
    if (selected.assistantMembershipId == normalized) return true;
    final owner = selected.localOwnerMembership;
    if (owner == null) return false;
    return _guard('assistant-set', () async {
      await _service.execute({
        'action': 'conversation.assistant.set',
        'conversationId': selected.id,
        'ownerMembershipId': owner.id,
        'expectedRevision': selected.revision,
        'membershipId': normalized.isEmpty ? null : normalized,
      });
      await _refreshCatalogWithoutGuard();
      await _loadSelected();
    });
  }

  /// Returns deterministic Membership candidates for the selected
  /// Conversation under optional hard filters.
  Future<Map<String, dynamic>> assistantProfileCandidates({
    Map<String, dynamic>? filters,
  }) async {
    final conversation = _selectedConversation;
    if (conversation == null || conversation.id.isEmpty) {
      throw const ClientConversationServiceFailure('conversation_not_found');
    }
    return _objectMap(
      await _service.execute({
        'action': 'conversation.profile.candidates',
        'conversationId': conversation.id,
        'filters': filters ?? const <String, dynamic>{},
      }),
    );
  }

  /// Persists one Membership's revisioned Profile intent.
  Future<Map<String, dynamic>> updateMembershipProfileIntent({
    required String membershipId,
    required int expectedRevision,
    required Map<String, dynamic> intent,
  }) async {
    final conversation = _selectedConversation;
    final owner = conversation?.localOwnerMembership;
    if (conversation == null || owner == null) {
      throw const ClientConversationServiceFailure('local_owner_required');
    }
    return _objectMap(
      await _service.execute({
        'action': 'conversation.profile.update',
        'conversationId': conversation.id,
        'membershipId': membershipId.trim(),
        'ownerMembershipId': owner.id,
        'expectedRevision': expectedRevision,
        'intent': intent,
      }),
    );
  }

  /// Reads one Membership's persistent Profile intent (null when absent).
  Future<Map<String, dynamic>?> membershipProfile(String membershipId) async {
    final value = await _service.execute({
      'action': 'conversation.profile.get',
      'membershipId': membershipId.trim(),
    });
    return value is Map ? _objectMap(value) : null;
  }

  Future<bool> postMessage(
    String text, {
    bool dispatch = true,
    bool suppressAssistant = false,
    List<ConversationAttachment> attachments = const [],
  }) async {
    final conversation = _selectedConversation;
    final content = text.trim();
    final author = conversation?.localOwnerMembership;
    if (conversation == null ||
        author == null ||
        (content.isEmpty && attachments.isEmpty) ||
        _sending) {
      return false;
    }
    _sending = true;
    _clearFailure();
    _publishChange();
    try {
      final posted = await _service.execute({
        'action': 'conversation.message.post',
        'conversationId': conversation.id,
        'authorMembershipId': author.id,
        'content': content,
        if (attachments.isNotEmpty)
          'attachments': [
            for (final attachment in attachments)
              {
                'path': attachment.path,
                'name': attachment.name,
                'mediaType': attachment.mediaType,
              },
          ],
      });
      final eventId = _postedEventId(posted);
      if (eventId == null || eventId.isEmpty) {
        throw const ClientConversationServiceFailure('invalid_response');
      }
      _draft = '';
      try {
        await _loadSelected();
        _publishChange();
      } catch (_) {
        // The Message Event is already durable. A readback failure must not
        // skip dispatch; the post-dispatch reload still reconciles.
      }
      if (dispatch) {
        try {
          final dispatched = await _service.execute({
            'action': 'conversation.dispatch.after-post',
            'conversationId': conversation.id,
            'eventId': eventId,
            'suppressAssistant': suppressAssistant,
          });
          _liveTurns = _postedLiveTurns(dispatched);
          _dispatchPending = _liveTurns.isNotEmpty;
          if (dispatched is Map) {
            final strategyError = dispatched['strategyError'];
            if (strategyError is Map) {
              final code = (strategyError['code'] ?? '').toString().trim();
              if (code.isNotEmpty) {
                final stage = (strategyError['stage'] ?? 'strategy/start')
                    .toString()
                    .trim();
                _recordFailure(
                  stage.isEmpty ? 'strategy/start' : stage,
                  code,
                  conversationId: conversation.id,
                  strategyCode: code,
                );
                _dispatchPending = false;
              }
            }
          }
        } on ClientConversationServiceFailure catch (failure) {
          _recordFailure('send', failure.code, conversationId: conversation.id);
          await _persistDispatchFailure(
            conversationId: conversation.id,
            eventId: eventId,
            code: failure.code,
          );
          _liveTurns = const [];
          _dispatchPending = false;
        } catch (_) {
          await _persistDispatchFailure(
            conversationId: conversation.id,
            eventId: eventId,
            code: 'conversation_dispatch_failed',
          );
          _liveTurns = const [];
          _dispatchPending = false;
        }
      } else {
        _liveTurns = const [];
        _dispatchPending = false;
      }
      await _refreshCatalogWithoutGuard();
      await _loadSelected();
      return true;
    } on ClientConversationServiceFailure catch (failure) {
      _recordFailure('send', failure.code, conversationId: conversation.id);
      _liveTurns = const [];
      _dispatchPending = false;
      return false;
    } catch (_) {
      _liveTurns = const [];
      _dispatchPending = false;
      return false;
    } finally {
      _sending = false;
      _publishChange();
    }
  }

  /// Preserve the split persist-then-dispatch outcome. If transport fails
  /// after the user Event committed, a causal diagnostic makes that ordinary
  /// bubble durably retryable after refresh or relaunch.
  Future<void> _persistDispatchFailure({
    required String conversationId,
    required String eventId,
    required String code,
  }) async {
    try {
      await _service.execute({
        'action': 'conversation.event.append',
        'conversationId': conversationId,
        'kind': 'message',
        'parts': [
          {
            'kind': 'diagnostic',
            'content': jsonEncode({
              'code': code.trim().isEmpty
                  ? 'conversation_dispatch_failed'
                  : code.trim(),
              'stage': 'send',
            }),
          },
        ],
        'causationId': eventId,
        'finalized': true,
      });
    } catch (_) {
      // The original dispatch failure remains authoritative. Best-effort
      // diagnostic persistence must never replace or mask it.
    }
  }

  Future<bool> retryMessage(String eventId) async {
    final event = _eventById(eventId);
    if (event == null || !_eventHasFailedTurn(event.id)) return false;
    // The re-post below always authors as the local owner. Refuse to re-author
    // another Membership's Event under that identity; the original author and
    // its causal chain stay untouched instead.
    final owner = _selectedConversation?.localOwnerMembership;
    if (owner == null || event.authorMembershipId != owner.id) return false;
    final text = event.parts
        .where((part) => part.kind == ConversationEventPartKind.text)
        .map((part) => part.content)
        .join();
    final attachments = <ConversationAttachment>[];
    for (final part in event.parts) {
      if (part.kind != ConversationEventPartKind.image) continue;
      try {
        final decoded = jsonDecode(part.content);
        if (decoded is! Map) continue;
        final path = (decoded['path'] ?? '').toString().trim();
        if (path.isEmpty) continue;
        attachments.add(
          ConversationAttachment(
            id: part.id,
            name: (decoded['name'] ?? '').toString().trim(),
            mediaType: (decoded['mediaType'] ?? '').toString().trim(),
            path: path,
          ),
        );
      } catch (_) {
        continue;
      }
    }
    final posted = await postMessage(text, attachments: attachments);
    if (!posted) return false;
    return deleteMessage(eventId);
  }

  Future<bool> deleteMessage(String eventId) {
    final conversation = _selectedConversation;
    final owner = conversation?.localOwnerMembership;
    if (conversation == null || owner == null || _eventById(eventId) == null) {
      return Future.value(false);
    }
    return _guard('delete', () async {
      await _service.execute({
        'action': 'conversation.message.delete',
        'conversationId': conversation.id,
        'eventId': eventId,
        'ownerMembershipId': owner.id,
      });
      _historyGenerations[conversation.id] =
          (_historyGenerations[conversation.id] ?? 0) + 1;
      await _refreshCatalogWithoutGuard();
      await _loadSelected();
    });
  }

  ClientConversationEvent? _eventById(String eventId) {
    for (final event in _events) {
      if (event.id == eventId) return event;
    }
    return null;
  }

  bool _eventHasFailedTurn(String eventId) => _events.any(
    (event) =>
        event.finalized &&
        event.causationId == eventId &&
        event.parts.any((part) {
          if (part.kind != ConversationEventPartKind.diagnostic) return false;
          try {
            final decoded = jsonDecode(part.content);
            return decoded is Map &&
                (decoded['code'] ?? '').toString().trim().isNotEmpty;
          } catch (_) {
            return false;
          }
        }),
  );

  Future<bool> createGroup({
    required String title,
    required List<ClientConversationGroupMemberDraft> members,
  }) async {
    await _waitUntilIdle();
    return _guard('create', () async {
      final normalizedTitle = title.trim();
      final uniqueMembers = <String, ClientConversationGroupMemberDraft>{
        for (final member in members)
          if (member.agentId.trim().isNotEmpty)
            member.agentId.trim(): ClientConversationGroupMemberDraft(
              agentId: member.agentId.trim(),
              displayName: member.displayName.trim().isEmpty
                  ? member.agentId.trim()
                  : member.displayName.trim(),
            ),
      }.values.toList(growable: false);
      if (normalizedTitle.isEmpty || uniqueMembers.isEmpty) {
        throw const ClientConversationServiceFailure('invalid_request');
      }
      final created = _objectMap(
        await _service.execute({
          'action': 'conversation.create',
          'title': normalizedTitle,
          'owner': {
            'id': 'human:local',
            'kind': 'human',
            'displayName': 'Local User',
          },
          'members': [
            for (final member in uniqueMembers)
              {
                'principal': {
                  'id': 'agent:${member.agentId}',
                  'kind': 'agent',
                  'displayName': member.displayName,
                  'agentId': member.agentId,
                },
                'access': 'member',
              },
          ],
        }),
      );
      final conversationId = (created['id'] ?? '').toString();
      await _refreshCatalogWithoutGuard();
      _selectedConversationId = conversationId;
      _onSelectionChanged?.call(conversationId);
      await _loadSelected();
    });
  }

  Future<void> archiveSelected() async {
    await archiveConversation(_selectedConversationId);
  }

  Future<bool> archiveConversation(String conversationId) async {
    await _waitUntilIdle();
    final id = conversationId.trim();
    if (id.isEmpty) return false;
    return _guard('archive', conversationId: id, () async {
      final response = _objectMap(
        await _service.execute({
          'action': 'conversation.archive',
          'conversationId': id,
          'archived': true,
        }),
      );
      _applyArchiveReport(response);
      if (_selectedConversationId == id) {
        _clearSelection();
      }
      _reconcileCatalogInBackground();
    });
  }

  /// Archives the selected group with everything it involves and opens its
  /// fresh successor: one store transaction archives the conversation, its
  /// continuity children, and the member native sessions, while the old
  /// native transports are disconnected off the response path. The foreground
  /// applies the list change directly and selects the successor; a
  /// background-priority catalog read reconciles ordering later.
  Future<bool> archiveAndReopenSelected() async {
    final conversation = _selectedConversation;
    if (conversation == null || !conversation.group) return false;
    if (_sending || _dispatchPending || _liveTurns.isNotEmpty) {
      surfaceFailure('canonical-archive', 'conversation_clear_blocked');
      return false;
    }
    await _waitUntilIdle();
    final selected = _selectedConversation;
    if (selected == null || selected.id != conversation.id || !selected.group) {
      return false;
    }
    return _guard('archive', conversationId: selected.id, () async {
      final response = _objectMap(
        await _service.execute({
          'action': 'conversation.archive',
          'conversationId': selected.id,
          'archived': true,
          'reopen': true,
        }),
      );
      _applyArchiveReport(response);
      final successorId =
          _objectMap(response['successor'])['id']?.toString() ?? '';
      if (successorId.isEmpty) {
        throw const ClientConversationServiceFailure('invalid_response');
      }
      _conversationCache.remove(selected.id);
      _earlierPageErrors.remove(selected.id);
      _liveTurns = const [];
      _dispatchPending = false;
      _selectedConversationId = successorId;
      _onSelectionChanged?.call(successorId);
      await _loadSelected();
      _reconcileCatalogInBackground();
    });
  }

  /// Applies one archive report to the in-memory lists so the foreground
  /// refreshes immediately: the retired conversations move to the archived
  /// partition and the successor joins the active list, with no full catalog
  /// readback on the user's path.
  void _applyArchiveReport(Map<String, dynamic> response) {
    final retired = <String>{
      (response['conversationId'] ?? '').toString(),
      ...?(response['archivedChildIds'] as List?)?.map((id) => id.toString()),
    }..removeWhere((id) => id.isEmpty);
    if (retired.isEmpty) return;
    for (final id in retired) {
      // Any in-flight page or snapshot read for a retired conversation must
      // never land: archiving ends its visible history.
      _historyGenerations[id] = (_historyGenerations[id] ?? 0) + 1;
      _conversationCache.remove(id);
      _earlierPageErrors.remove(id);
    }
    final nowArchived = _summaries
        .where((summary) => retired.contains(summary.id))
        .map(
          (summary) => ClientConversationSummary(
            id: summary.id,
            title: summary.title,
            archived: true,
            pinned: summary.pinned,
            group: summary.group,
            revision: summary.revision + 1,
            updatedAtUnixMs: summary.updatedAtUnixMs,
            membershipCount: summary.membershipCount,
            eventCount: summary.eventCount,
            parentConversationId: summary.parentConversationId,
            taskGoalId: summary.taskGoalId,
            listingKind: summary.listingKind,
          ),
        )
        .toList(growable: false);
    _summaries = _summaries
        .where((summary) => !retired.contains(summary.id))
        .toList(growable: false);
    if (nowArchived.isNotEmpty) {
      _archivedSummaries = [
        ...nowArchived,
        ..._archivedSummaries.where((entry) => !retired.contains(entry.id)),
      ];
    }
    final successor = _objectMap(response['successor']);
    if (successor.isNotEmpty) {
      final memberships = successor['memberships'];
      _summaries = [
        ClientConversationSummary(
          id: (successor['id'] ?? '').toString(),
          title: (successor['title'] ?? '').toString(),
          archived: false,
          group: successor['isGroup'] == true,
          revision: _archiveSummaryInt(successor['revision']),
          updatedAtUnixMs: _archiveSummaryInt(successor['updatedAtUnixMs']),
          membershipCount: memberships is List ? memberships.length : 0,
          eventCount: _archiveSummaryInt(successor['eventCount']),
        ),
        ..._summaries,
      ];
    }
    _publishChange();
  }

  /// Reconciles the catalog after an archive without holding the foreground:
  /// queued behind background priority so a pending user command always wins.
  void _reconcileCatalogInBackground() {
    unawaited(
      runWithRpcPriorityToken(RpcPriorityToken(background: true), () async {
        try {
          await _refreshCatalogWithoutGuard();
        } catch (_) {
          // A failed background reconcile self-heals on the next refresh.
        }
      }),
    );
  }

  Future<bool> refreshArchived() async {
    await _waitUntilIdle();
    return _guard(
      'archived-list',
      _refreshArchivedWithoutGuard,
      conversationId: '',
    );
  }

  Future<bool> restoreArchived(String conversationId) async {
    await _waitUntilIdle();
    final id = conversationId.trim();
    return _guard('restore', conversationId: id.isEmpty ? null : id, () async {
      if (id.isEmpty) {
        throw const ClientConversationServiceFailure('invalid_request');
      }
      await _service.execute({
        'action': 'conversation.archive',
        'conversationId': id,
        'archived': false,
      });
      await _refreshCatalogWithoutGuard();
    });
  }

  Future<void> setPinned(String conversationId, bool pinned) async {
    await _waitUntilIdle();
    final id = conversationId.trim();
    await _guard('pin', conversationId: id.isEmpty ? null : id, () async {
      if (id.isEmpty) {
        throw const ClientConversationServiceFailure('invalid_request');
      }
      await _service.execute({
        'action': 'conversation.pin.set',
        'conversationId': id,
        'pinned': pinned,
      });
      await _refreshCatalogWithoutGuard();
      if (_selectedConversationId == id) {
        await _loadSelected();
      }
    });
  }

  Future<void> _refreshCatalogWithoutGuard() async {
    // One native snapshot includes both partitions and their lineage. Reading
    // the active catalog separately repeats the same store scan and counts.
    final summaries = _summaryList(
      await _service.execute({
        'action': 'conversation.list',
        'includeArchived': true,
      }),
    );
    if (_disposed) return;
    _summaries = summaries
        .where((item) => !item.archived)
        .toList(growable: false);
    _archivedSummaries = summaries
        .where((item) => item.archived)
        .toList(growable: false);
    _discardStaleConversationSnapshots();
  }

  void _discardStaleConversationSnapshots() {
    final summariesById = {
      for (final summary in _summaries) summary.id: summary,
    };
    _conversationCache.removeWhere((id, cached) {
      final summary = summariesById[id];
      if (summary == null) return true;
      // The selected window is reconciled by _loadSelected below. Keeping it
      // here retains pages the reader opened when a post updates the catalog.
      if (id == _selectedConversationId) return false;
      final conversation = cached.conversation;
      return summary.revision != conversation.revision ||
          summary.updatedAtUnixMs != conversation.updatedAtUnixMs ||
          summary.eventCount != conversation.eventCount;
    });
  }

  bool _isListedConversation(String id) {
    if (_summaries.any((conversation) => conversation.id == id)) {
      return true;
    }
    return groupConversations.any(
      (group) => group.archivedChildren.any((child) => child.id == id),
    );
  }

  Future<void> _refreshArchivedWithoutGuard() async {
    _archivedSummaries = _summaryList(
      await _service.execute({
        'action': 'conversation.list',
        'includeArchived': true,
      }),
    ).where((conversation) => conversation.archived).toList(growable: false);
  }

  /// Reloads the selected transcript so streamed group events can appear
  /// while a strategy actor is still running. Returns whether a complete
  /// selected snapshot was applied; callers retain live state on failure.
  Future<bool> reloadSelected() async {
    if (_disposed || _selectedConversationId.isEmpty) return false;
    try {
      await _loadSelected();
      if (!_disposed) _publishChange();
      return !_disposed;
    } catch (_) {
      return false;
    }
  }

  /// Adds one preceding native page without changing the selected surface or
  /// its live turns. Sparse task-card recovery is never a history cursor.
  Future<void> loadEarlierEvents() async {
    final id = _selectedConversationId;
    final cached = _conversationCache[id];
    final before = cached?.nextBeforeSequence;
    if (_disposed ||
        cached == null ||
        !cached.hasEarlier ||
        before == null ||
        !_loadingEarlierConversations.add(id)) {
      return;
    }
    final generation = _historyGenerations[id] ?? 0;
    _earlierPageErrors.remove(id);
    _publishChange();
    try {
      final page = await _readEventPage(id, beforeSequence: before);
      if (_disposed || (_historyGenerations[id] ?? 0) != generation) return;
      final current = _conversationCache[id];
      if (current == null) return;
      if (page.hasEarlier &&
          (page.nextBeforeSequence == null ||
              page.nextBeforeSequence! >= before)) {
        throw const ClientConversationServiceFailure(
          'conversation_events_page_no_progress',
        );
      }
      final events = _mergeEventPages(page.events, current.events);
      final next = _CachedClientConversation(
        conversation: current.conversation,
        events: events,
        taskViews: current.taskViews,
        windowStartSequence: page.events.isEmpty
            ? current.windowStartSequence
            : page.events.first.sequence,
        hasEarlier: page.hasEarlier,
        nextBeforeSequence: page.nextBeforeSequence,
      );
      _conversationCache[id] = next;
      if (_selectedConversationId == id) {
        _applySelectedSnapshot(next.conversation, events);
      }
    } on ClientConversationServiceFailure catch (failure) {
      if ((_historyGenerations[id] ?? 0) == generation) {
        _earlierPageErrors[id] = failure.code;
      }
    } catch (_) {
      if ((_historyGenerations[id] ?? 0) == generation) {
        _earlierPageErrors[id] = 'conversation_events_page_failed';
      }
    } finally {
      _loadingEarlierConversations.remove(id);
      _publishChange();
    }
  }

  Future<ClientConversationEventPage> _readEventPage(
    String id, {
    bool latest = false,
    int? beforeSequence,
    int? afterSequence,
    int limit = _eventPageSize,
  }) async => ClientConversationEventPage.fromJson(
    _objectMap(
      await _service.execute({
        'action': 'conversation.events.page',
        'conversationId': id,
        if (latest) 'latest': true,
        'beforeSequence': ?beforeSequence,
        'afterSequence': ?afterSequence,
        'limit': limit,
      }),
    ),
  );

  Future<void> _loadSelected() async {
    final id = _selectedConversationId;
    if (id.isEmpty) return;
    await _loadConversation(id);
  }

  Future<void> _loadConversation(String id) async {
    final generation = _historyGenerations[id] ?? 0;
    final raw = _objectMap(
      await _service.execute({
        'action': 'conversation.get',
        'conversationId': id,
        'includeNativeSessionReferences': true,
      }),
    );
    if (_disposed || (_historyGenerations[id] ?? 0) != generation) return;
    await _applySelectedRaw(id, raw);
  }

  /// Applies one already-read conversation snapshot: reads the transcript page
  /// for that revision, updates the cache, and replaces the selected surface.
  ///
  /// Split from [_loadSelected] so a caller that already holds a fresh
  /// `conversation.get` result does not read the same record twice.
  Future<void> _applySelectedRaw(String id, Map<String, dynamic> raw) async {
    final conversation = ClientConversation.fromJson(raw);
    final cached = _conversationCache[id];
    if (cached != null &&
        cached.conversation.revision > conversation.revision) {
      return;
    }
    final generation = _historyGenerations[id] ?? 0;
    final readVersion = (_latestReadVersions[id] ?? 0) + 1;
    _latestReadVersions[id] = readVersion;
    final stagedTaskViews = _maps(raw['taskViews']);
    final page = await _readEventPage(id, latest: true);
    bool currentRead() =>
        !_disposed &&
        (_historyGenerations[id] ?? 0) == generation &&
        _latestReadVersions[id] == readVersion;
    if (!currentRead()) return;

    final preceding = <ClientConversationEvent>[];
    final previous = _conversationCache[id];
    final removedEvents =
        previous != null &&
        conversation.eventCount < previous.conversation.eventCount;
    ClientConversationEventPage? repairedWindow;
    if (previous != null &&
        previous.events.isNotEmpty &&
        page.events.isNotEmpty) {
      var after = removedEvents
          ? (previous.windowStartSequence ?? page.events.first.sequence) - 1
          : previous.events.last.sequence;
      final newestStart = page.events.first.sequence;
      // One native observation can contain more than twenty new events. Fill
      // only that gap in bounded pages; the captured newest page is our stop.
      // A deletion rechecks only the already-opened window, also twenty at a
      // time, so a removed older row cannot survive in the retained cache.
      while (after + 1 < newestStart) {
        final missing = await _readEventPage(id, afterSequence: after);
        if (removedEvents) repairedWindow ??= missing;
        if (!currentRead()) return;
        if (missing.events.isEmpty || missing.events.last.sequence <= after) {
          throw const ClientConversationServiceFailure(
            'conversation_events_page_no_progress',
          );
        }
        preceding.addAll(
          missing.events.where((event) => event.sequence < newestStart),
        );
        after = missing.events.last.sequence;
      }
    }

    // Re-read the cache after awaits: an earlier page may have finished while
    // this latest page was loading. The latest range replaces its old copy so
    // changed event parts and deletions in that range become authoritative.
    final current = _conversationCache[id];
    final retained = page.events.isEmpty || removedEvents
        ? const <ClientConversationEvent>[]
        : current?.events
                  .where((event) => event.sequence < page.events.first.sequence)
                  .toList(growable: false) ??
              const <ClientConversationEvent>[];
    final merged = _mergeEventPages(retained, [...preceding, ...page.events]);
    var events = List<ClientConversationEvent>.unmodifiable(
      await _recoverAnchoredCardEvents(id, merged, stagedTaskViews),
    );
    if (!currentRead()) return;
    final afterRecovery = _conversationCache[id];
    final loadedEarlierDuringRecovery =
        afterRecovery?.windowStartSequence != null &&
        current?.windowStartSequence != null &&
        afterRecovery!.windowStartSequence! < current!.windowStartSequence!;
    if (loadedEarlierDuringRecovery) {
      events = _mergeEventPages(
        afterRecovery.events
            .where((event) => event.sequence < current.windowStartSequence!)
            .toList(growable: false),
        events,
      );
    }
    final window = loadedEarlierDuringRecovery ? afterRecovery : current;
    final hasRetainedWindow =
        window?.windowStartSequence != null &&
        page.events.isNotEmpty &&
        window!.windowStartSequence! < page.events.first.sequence;
    final next = _CachedClientConversation(
      conversation: conversation,
      events: events,
      taskViews: stagedTaskViews,
      windowStartSequence: hasRetainedWindow
          ? (repairedWindow?.events.firstOrNull?.sequence ??
                window.windowStartSequence)
          : page.events.firstOrNull?.sequence,
      hasEarlier: hasRetainedWindow
          ? (repairedWindow?.hasEarlier ?? window.hasEarlier)
          : page.hasEarlier,
      nextBeforeSequence: hasRetainedWindow
          ? (repairedWindow == null
                ? window.nextBeforeSequence
                : repairedWindow.nextBeforeSequence)
          : page.nextBeforeSequence,
    );
    _conversationCache[id] = next;
    if (_selectedConversationId != id) return;
    _selectedTaskViews = stagedTaskViews;
    _applySelectedSnapshot(conversation, events);
  }

  Future<List<ClientConversationEvent>> _recoverAnchoredCardEvents(
    String conversationId,
    List<ClientConversationEvent> window,
    List<Map<String, dynamic>> taskViews,
  ) async {
    final present = <int>{for (final event in window) event.sequence};
    final recovered = <ClientConversationEvent>[];
    for (final view in taskViews) {
      final relation = view['relation'];
      if (relation is! Map) continue;
      final anchor = relation['cardAnchor'];
      if (anchor is! Map) continue;
      final sequence = (anchor['sequence'] as num?)?.toInt();
      if (sequence == null || sequence <= 0 || present.contains(sequence)) {
        continue;
      }
      final page = await _readEventPage(
        conversationId,
        afterSequence: sequence - 1,
        limit: 1,
      );
      for (final event in page.events) {
        if (event.sequence == sequence && present.add(sequence)) {
          recovered.add(event);
        }
      }
    }
    recovered.sort((left, right) => left.sequence.compareTo(right.sequence));
    return _mergeEventPages(window, recovered);
  }

  void _applySelectedSnapshot(
    ClientConversation conversation,
    List<ClientConversationEvent> events,
  ) {
    _selectedConversation = conversation;
    _events = events;
    _onSnapshotApplied?.call(conversation);
    _recentParticipants.applySnapshot(
      conversation: conversation,
      events: _events,
      availableLocalAgentIds: _availableConversationAgentIds,
    );
  }

  Future<void> _waitUntilIdle() async {
    while (_loading) {
      final completion = _loadingCompletion;
      if (completion == null) return;
      await completion.future;
    }
  }

  /// Runs one mutation under the loading latch. A failure is attributed to
  /// [conversationId], or — when it is null — to the Conversation selected
  /// when the operation started, never to whatever the user happens to view
  /// when the asynchronous failure lands. An explicitly empty
  /// [conversationId] keeps the failure global (for example a catalog read),
  /// so it stays visible across a selection change.
  Future<bool> _guard(
    String stage,
    Future<void> Function() operation, {
    String? conversationId,
  }) async {
    if (_loading) return false;
    final originId = conversationId?.trim() ?? _selectedConversationId;
    _loading = true;
    final loadingCompletion = Completer<void>();
    _loadingCompletion = loadingCompletion;
    _clearFailure();
    _publishChange();
    try {
      await operation();
      return true;
    } on ClientConversationServiceFailure catch (failure) {
      _recordFailure(stage, failure.code, conversationId: originId);
      return false;
    } catch (_) {
      return false;
    } finally {
      _loading = false;
      if (!loadingCompletion.isCompleted) loadingCompletion.complete();
      if (identical(_loadingCompletion, loadingCompletion)) {
        _loadingCompletion = null;
      }
      _publishChange();
    }
  }

  void _clearSelection() {
    final changed = _selectedConversationId.isNotEmpty;
    _selectedConversationId = '';
    _selectedConversation = null;
    _events = const [];
    _selectedTaskViews = const [];
    _recentParticipants.clear();
    _draft = '';
    _liveTurns = const [];
    _dispatchPending = false;
    if (changed) _onSelectionChanged?.call('');
  }

  void _publishChange() {
    if (_disposed) return;
    _observeMemory();
    publishChange();
  }

  void _observeMemory() {
    final journal = _memoryJournal;
    if (journal == null) return;
    final open = _selectedConversationId.isNotEmpty;
    final liveTurnCount = _liveTurns.length;
    ClientMemoryDiagnosticEvent event;
    if (open && !_memoryConversationOpen) {
      event = ClientMemoryDiagnosticEvent.conversationOpened;
    } else if (!open && _memoryConversationOpen) {
      event = ClientMemoryDiagnosticEvent.conversationClosed;
    } else if (open && liveTurnCount > 0 && _memoryLiveTurnCount == 0) {
      event = ClientMemoryDiagnosticEvent.liveTurnOpened;
    } else if (open && liveTurnCount == 0 && _memoryLiveTurnCount > 0) {
      event = ClientMemoryDiagnosticEvent.liveTurnClosed;
    } else if (open) {
      event = ClientMemoryDiagnosticEvent.sample;
    } else {
      _memoryConversationOpen = false;
      _memoryLiveTurnCount = 0;
      return;
    }
    _memoryConversationOpen = open;
    _memoryLiveTurnCount = liveTurnCount;
    journal.observe(
      ClientMemoryDiagnosticObservation(
        event: event,
        surface: ClientMemoryDiagnosticSurface.canonical,
        eventCount: _selectedConversation?.eventCount ?? 0,
        loadedEventCount: _events.length,
        liveTurnCount: liveTurnCount,
        livePartCount: _livePartCount(_liveTurns),
        cachedConversationCount: _conversationCache.length,
      ),
    );
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _pendingNoticeTimer?.cancel();
    _pendingNoticeTimer = null;
    _activityEchoTimer?.cancel();
    _activityEchoTimer = null;
    if (_memoryConversationOpen) {
      _selectedConversationId = '';
      _liveTurns = const [];
      _observeMemory();
    }
    super.dispose();
  }
}

final class _CachedClientConversation {
  const _CachedClientConversation({
    required this.conversation,
    required this.events,
    required this.windowStartSequence,
    required this.hasEarlier,
    required this.nextBeforeSequence,
    this.taskViews = const <Map<String, dynamic>>[],
  });

  final ClientConversation conversation;
  final List<ClientConversationEvent> events;
  final int? windowStartSequence;
  final bool hasEarlier;
  final int? nextBeforeSequence;
  final List<Map<String, dynamic>> taskViews;
}

/// Native pages are sequence-ordered. A linear merge keeps stable identities
/// for retained rows and lets the newer page replace revised event content.
List<ClientConversationEvent> _mergeEventPages(
  List<ClientConversationEvent> retained,
  List<ClientConversationEvent> incoming,
) {
  final merged = <ClientConversationEvent>[];
  var left = 0;
  var right = 0;
  while (left < retained.length && right < incoming.length) {
    final old = retained[left];
    final next = incoming[right];
    if (old.sequence < next.sequence) {
      merged.add(old);
      left += 1;
    } else {
      merged.add(next);
      right += 1;
      if (old.sequence == next.sequence) left += 1;
    }
  }
  merged.addAll(retained.skip(left));
  merged.addAll(incoming.skip(right));
  return List<ClientConversationEvent>.unmodifiable(merged);
}

List<ClientConversationSummary> _summaryList(Object? value) => value is List
    ? value
          .whereType<Map>()
          .map(
            (entry) => ClientConversationSummary.fromJson(
              Map<String, dynamic>.from(entry),
            ),
          )
          .toList(growable: false)
    : const <ClientConversationSummary>[];

Map<String, dynamic> _objectMap(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : const <String, dynamic>{};

int _archiveSummaryInt(Object? value) =>
    value is num ? value.toInt() : int.tryParse('$value') ?? 0;

List<String> _profileStringList(Object? value) => value is List
    ? value
          .map((entry) => entry.toString().trim())
          .where((entry) => entry.isNotEmpty)
          .toList(growable: false)
    : const <String>[];

bool _sameStringList(List<String> left, List<String> right) {
  if (left.length != right.length) return false;
  for (var index = 0; index < left.length; index += 1) {
    if (left[index] != right[index]) return false;
  }
  return true;
}

String? _postedEventId(Object? posted) {
  if (posted is! Map) return null;
  final event = posted['event'];
  if (event is Map) {
    final id = (event['id'] ?? '').toString().trim();
    if (id.isNotEmpty) return id;
  }
  return null;
}

List<Map<String, dynamic>> _postedLiveTurns(Object? posted) {
  if (posted is! Map) return const [];
  final turns = posted['turns'];
  if (turns is! List) return const [];
  return [
    for (final turn in turns)
      if (turn is Map) Map<String, dynamic>.from(turn),
  ];
}

List<Map<String, dynamic>> _maps(Object? value) => value is List
    ? value
          .whereType<Map>()
          .map(Map<String, dynamic>.from)
          .toList(growable: false)
    : const <Map<String, dynamic>>[];

int _livePartCount(List<Map<String, dynamic>> turns) {
  var count = 0;
  for (final turn in turns) {
    final parts = turn['parts'];
    count += parts is List ? parts.length : 1;
  }
  return count;
}
