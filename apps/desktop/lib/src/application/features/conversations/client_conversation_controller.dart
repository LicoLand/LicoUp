import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:licoup/src/backend/features/conversations/services/client_conversation_service.dart';
import 'package:licoup/src/application/features/conversations/client_conversation_recent_participants.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/contracts/client_conversation_models.dart';
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
  List<ClientConversationSummary> _summaries = const [];
  List<ClientConversationSummary> _archivedSummaries = const [];
  ClientConversation? _selectedConversation;
  List<ClientConversationEvent> _events = const [];
  final ClientConversationRecentParticipants _recentParticipants =
      ClientConversationRecentParticipants();
  List<String> _availableConversationAgentIds = const [];

  bool get loading => _loading;
  bool get sending => _sending;
  String get selectedConversationId => _selectedConversationId;
  String get draft => _draft;
  String get failureStage => _failureStage;
  String get failureCode => _failureCode;
  ClientConversation? get selectedConversation => _selectedConversation;
  List<ClientConversationEvent> get events => _events;
  List<String> get recentParticipantAgentIds => _recentParticipants.agentIds;
  List<ClientConversationSummary> get archivedConversations =>
      _archivedSummaries;

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
    await _guard('open', () async {
      final normalized = conversationId.trim();
      if (normalized.isEmpty) {
        _clearSelection();
        return;
      }
      final changed = _selectedConversationId != normalized;
      _selectedConversationId = normalized;
      _draft = '';
      if (changed) _onSelectionChanged?.call(normalized);
      await _loadSelected();
    });
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

  Future<bool> postMessage(String text) async {
    final conversation = _selectedConversation;
    final content = text.trim();
    final author = conversation?.localOwnerMembership;
    if (conversation == null || author == null || content.isEmpty || _sending) {
      return false;
    }
    _sending = true;
    _failureStage = '';
    _failureCode = '';
    _notifyListeners();
    try {
      final mentioned = _mentionedMembershipIds(content, conversation);
      await _service.execute(_runner, {
        'action': 'conversation.message.post',
        'conversationId': conversation.id,
        'authorMembershipId': author.id,
        'content': content,
        'mentionedMembershipIds': mentioned,
      });
      _draft = '';
      await _refreshCatalogWithoutGuard();
      await _loadSelected();
      return true;
    } on ClientConversationServiceFailure catch (failure) {
      _failureStage = 'send';
      _failureCode = failure.code;
      return false;
    } catch (_) {
      _failureStage = 'send';
      _failureCode = 'conversation_operation_failed';
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
  }

  Future<void> _refreshArchivedWithoutGuard() async {
    _archivedSummaries = _summaryList(
      await _service.execute(_runner, {
        'action': 'conversation.list',
        'includeArchived': true,
      }),
    ).where((conversation) => conversation.archived).toList(growable: false);
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
    _selectedConversation = conversation;
    _events = page.events;
    _recentParticipants.applySnapshot(
      conversation: conversation,
      events: _events,
      availableLocalAgentIds: _availableConversationAgentIds,
    );
  }

  List<String> _mentionedMembershipIds(
    String content,
    ClientConversation conversation,
  ) {
    final result = <String>[];
    for (final membership in conversation.activeAgentMemberships) {
      final aliases = {
        membership.principal.displayName.trim(),
        membership.principal.agentId.trim(),
      }.where((alias) => alias.isNotEmpty);
      final mentioned = aliases.any((alias) {
        final escaped = RegExp.escape(alias);
        return RegExp(
          '(^|\\s)@$escaped(?=\\s|[,.!?;:，。！？；：]|\$)',
          caseSensitive: false,
        ).hasMatch(content);
      });
      if (mentioned) result.add(membership.id);
    }
    return List<String>.unmodifiable(result);
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
    _failureStage = '';
    _failureCode = '';
    _notifyListeners();
    try {
      await operation();
      return true;
    } on ClientConversationServiceFailure catch (failure) {
      _failureStage = stage;
      _failureCode = failure.code;
      return false;
    } catch (_) {
      _failureStage = stage;
      _failureCode = 'conversation_operation_failed';
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
