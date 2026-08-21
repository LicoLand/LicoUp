import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:licoup/src/backend/features/conversations/services/client_conversation_service.dart';
import 'package:licoup/src/application/features/conversations/client_conversation_recent_participants.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/contracts/client_conversation_models.dart';
import 'package:licoup/src/contracts/problem_codes/problem_codes.dart';
import 'package:licoup/src/contracts/target_candidate.dart';

final class ClientConversationController extends ChangeNotifier {
  ClientConversationController({
    required AgentCommandRunner runner,
    ClientConversationService service = const ClientConversationService(),
    void Function(String conversationId)? onSelectionChanged,
  }) : _runner = runner,
       _service = service,
       _onSelectionChanged = onSelectionChanged;

  final AgentCommandRunner _runner;
  final ClientConversationService _service;
  final void Function(String conversationId)? _onSelectionChanged;

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
  final ClientConversationRecentParticipants _recentParticipants =
      ClientConversationRecentParticipants();
  List<String> _availableConversationAgentIds = const [];

  bool get loading => _loading;
  bool get sending => _sending;
  String get selectedConversationId => _selectedConversationId;
  String get draft => _draft;
  String get failureStage => _failureStage;
  String get failureCode => _failureCode;
  String get failureRef => _failureRef;
  String get failureProblemCode => ProblemCodeCopy.problemCode(_failureCode);
  String get failureCopyBlob => ProblemCodeCopy.copyableDetail(
    legacyCode: _failureCode,
    stage: _failureStage,
    occurrenceId: _failureRef,
    occurredAt: _failureOccurredAt,
    strategyCode: _failureStrategyCode,
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
    _notifyListeners();
  }

  ClientConversation? get selectedConversation => _selectedConversation;
  List<ClientConversationEvent> get events => _events;
  List<String> get recentParticipantAgentIds => _recentParticipants.agentIds;
  List<ClientConversationSummary> get archivedConversations =>
      _archivedSummaries;

  /// Surfaces a group-operation failure on the conversation banner.
  void surfaceFailure(String stage, String code) {
    if (_disposed) return;
    final nextStage = stage.trim();
    final nextCode = code.trim();
    if (nextStage.isEmpty || nextCode.isEmpty) return;
    _recordFailure(nextStage, nextCode);
    _notifyListeners();
  }

  void _clearFailure() {
    _failureStage = '';
    _failureCode = '';
    _failureRef = '';
    _failureOccurredAt = '';
    _failureStrategyCode = '';
  }

  void _recordFailure(String stage, String code, {String strategyCode = ''}) {
    _failureStage = stage;
    _failureCode = code;
    _failureStrategyCode = strategyCode;
    _failureOccurredAt = DateTime.now().toUtc().toIso8601String();
    _failureSeq = (_failureSeq + 1) & 0xFFFF;
    final mixed =
        (DateTime.now().microsecondsSinceEpoch ^ (_failureSeq << 8)) & 0xFFFF;
    _failureRef = '#L-${mixed.toRadixString(16).toUpperCase().padLeft(4, '0')}';
  }

  List<ClientConversationSummary> get groupConversations => _summaries
      .where((conversation) => conversation.isGroup)
      .toList(growable: false);

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
      final succeeded = await _refresh();
      if (!_disposed && succeeded) _initialized = true;
    } finally {
      _initialization = null;
    }
  }

  Future<void> refresh() async {
    await _refresh();
  }

  Future<bool> _refresh() => _guard('list', () async {
    _summaries = _summaryList(
      await _service.execute(_runner, {
        'action': 'conversation.list',
        'includeArchived': false,
      }),
    );
    _discardStaleConversationSnapshots();
    if (_selectedConversationId.isNotEmpty &&
        !_summaries.any(
          (conversation) => conversation.id == _selectedConversationId,
        )) {
      _clearSelection();
    }
    if (_selectedConversationId.isNotEmpty) {
      await _loadSelected();
    }
  });

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
      _applySelectedSnapshot(cached.conversation, cached.events);
    }
    if (changed) _onSelectionChanged?.call(normalized);
    _notifyListeners();
    if (cached != null) return;
    await _waitUntilIdle();
    if (_disposed || _selectedConversationId != normalized) return;
    final loadedWhileWaiting = _conversationCache[normalized];
    if (loadedWhileWaiting != null) {
      _applySelectedSnapshot(
        loadedWhileWaiting.conversation,
        loadedWhileWaiting.events,
      );
      _notifyListeners();
      return;
    }
    await _guard('open', _loadSelected);
  }

  void clearSelection() {
    if (_selectedConversationId.isEmpty) return;
    _clearSelection();
    _notifyListeners();
  }

  void updateDraft(String value) {
    if (_draft == value) return;
    _draft = value;
    _notifyListeners();
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
    if (changed) _notifyListeners();
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
      await _service.execute(_runner, {
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
      await _service.execute(_runner, {
        'action': 'conversation.strategy.set',
        'conversationId': selected.id,
        'strategyRevision': normalized.isEmpty ? null : normalized,
      });
      await _refreshCatalogWithoutGuard();
      await _loadSelected();
    });
  }

  Future<bool> postMessage(String text) async {
    final conversation = _selectedConversation;
    final content = text.trim();
    final author = conversation?.localOwnerMembership;
    if (conversation == null || author == null || content.isEmpty || _sending) {
      return false;
    }
    _sending = true;
    _clearFailure();
    _notifyListeners();
    try {
      final posted = await _service.execute(_runner, {
        'action': 'conversation.message.post',
        'conversationId': conversation.id,
        'authorMembershipId': author.id,
        'content': content,
      });
      final eventId = _postedEventId(posted);
      if (eventId == null || eventId.isEmpty) {
        throw const ClientConversationServiceFailure('invalid_response');
      }
      _draft = '';
      _notifyListeners();
      try {
        final dispatched = await _service.execute(_runner, {
          'action': 'conversation.dispatch.after-post',
          'conversationId': conversation.id,
          'eventId': eventId,
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
                strategyCode: code,
              );
              _dispatchPending = false;
            }
          }
        }
      } on ClientConversationServiceFailure catch (failure) {
        _recordFailure('send', failure.code);
        _liveTurns = const [];
        _dispatchPending = false;
      } catch (_) {
        _liveTurns = const [];
        _dispatchPending = false;
      }
      await _refreshCatalogWithoutGuard();
      await _loadSelected();
      return true;
    } on ClientConversationServiceFailure catch (failure) {
      _recordFailure('send', failure.code);
      _liveTurns = const [];
      _dispatchPending = false;
      return false;
    } catch (_) {
      _liveTurns = const [];
      _dispatchPending = false;
      return false;
    } finally {
      _sending = false;
      _notifyListeners();
    }
  }

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
        await _service.execute(_runner, {
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
    await _guard('archive', () async {
      final id = _selectedConversationId;
      if (id.isEmpty) return;
      await _service.execute(_runner, {
        'action': 'conversation.archive',
        'conversationId': id,
        'archived': true,
      });
      _clearSelection();
      await _refreshCatalogWithoutGuard();
    });
  }

  Future<bool> refreshArchived() async {
    await _waitUntilIdle();
    return _guard('archived-list', _refreshArchivedWithoutGuard);
  }

  Future<bool> restoreArchived(String conversationId) async {
    await _waitUntilIdle();
    return _guard('restore', () async {
      final id = conversationId.trim();
      if (id.isEmpty) {
        throw const ClientConversationServiceFailure('invalid_request');
      }
      await _service.execute(_runner, {
        'action': 'conversation.archive',
        'conversationId': id,
        'archived': false,
      });
      await _refreshCatalogWithoutGuard();
      await _refreshArchivedWithoutGuard();
    });
  }

  Future<void> setPinned(String conversationId, bool pinned) async {
    await _waitUntilIdle();
    await _guard('pin', () async {
      final id = conversationId.trim();
      if (id.isEmpty) {
        throw const ClientConversationServiceFailure('invalid_request');
      }
      await _service.execute(_runner, {
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
    _summaries = _summaryList(
      await _service.execute(_runner, {
        'action': 'conversation.list',
        'includeArchived': false,
      }),
    );
    _discardStaleConversationSnapshots();
  }

  void _discardStaleConversationSnapshots() {
    final summariesById = {
      for (final summary in _summaries) summary.id: summary,
    };
    _conversationCache.removeWhere((id, cached) {
      final summary = summariesById[id];
      if (summary == null) return true;
      final conversation = cached.conversation;
      return summary.revision != conversation.revision ||
          summary.updatedAtUnixMs != conversation.updatedAtUnixMs ||
          summary.eventCount != conversation.eventCount;
    });
  }

  Future<void> _refreshArchivedWithoutGuard() async {
    _archivedSummaries = _summaryList(
      await _service.execute(_runner, {
        'action': 'conversation.list',
        'includeArchived': true,
      }),
    ).where((conversation) => conversation.archived).toList(growable: false);
  }

  /// Reloads the selected transcript so streamed group events can appear
  /// while a strategy actor is still running.
  Future<void> reloadSelected() async {
    if (_disposed || _selectedConversationId.isEmpty) return;
    try {
      await _loadSelected();
      if (!_disposed) _notifyListeners();
    } catch (_) {}
  }

  Future<void> _loadSelected() async {
    final id = _selectedConversationId;
    if (id.isEmpty) return;
    final conversation = ClientConversation.fromJson(
      _objectMap(
        await _service.execute(_runner, {
          'action': 'conversation.get',
          'conversationId': id,
        }),
      ),
    );
    // Sequence values are contiguous and monotonic. Starting at total-50
    // gives the required newest initial window without scanning old events.
    final afterSequence = conversation.eventCount > 50
        ? conversation.eventCount - 50
        : 0;
    final page = ClientConversationEventPage.fromJson(
      _objectMap(
        await _service.execute(_runner, {
          'action': 'conversation.events.page',
          'conversationId': id,
          'afterSequence': afterSequence,
          'limit': 50,
        }),
      ),
    );
    final events = List<ClientConversationEvent>.unmodifiable(page.events);
    _conversationCache[id] = _CachedClientConversation(
      conversation: conversation,
      events: events,
    );
    if (_selectedConversationId != id) return;
    _applySelectedSnapshot(conversation, events);
  }

  void _applySelectedSnapshot(
    ClientConversation conversation,
    List<ClientConversationEvent> events,
  ) {
    _selectedConversation = conversation;
    _events = events;
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

  Future<bool> _guard(String stage, Future<void> Function() operation) async {
    if (_loading) return false;
    _loading = true;
    final loadingCompletion = Completer<void>();
    _loadingCompletion = loadingCompletion;
    _clearFailure();
    _notifyListeners();
    try {
      await operation();
      return true;
    } on ClientConversationServiceFailure catch (failure) {
      _recordFailure(stage, failure.code);
      return false;
    } catch (_) {
      return false;
    } finally {
      _loading = false;
      if (!loadingCompletion.isCompleted) loadingCompletion.complete();
      if (identical(_loadingCompletion, loadingCompletion)) {
        _loadingCompletion = null;
      }
      _notifyListeners();
    }
  }

  void _clearSelection() {
    final changed = _selectedConversationId.isNotEmpty;
    _selectedConversationId = '';
    _selectedConversation = null;
    _events = const [];
    _recentParticipants.clear();
    _draft = '';
    _liveTurns = const [];
    _dispatchPending = false;
    if (changed) _onSelectionChanged?.call('');
  }

  void _notifyListeners() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    super.dispose();
  }
}

final class _CachedClientConversation {
  const _CachedClientConversation({
    required this.conversation,
    required this.events,
  });

  final ClientConversation conversation;
  final List<ClientConversationEvent> events;
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
