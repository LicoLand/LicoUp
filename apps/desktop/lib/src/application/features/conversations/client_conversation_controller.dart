import 'dart:async';

import 'package:flutter/foundation.dart';

import 'package:licoup/src/backend/features/conversations/services/client_conversation_service.dart';
import 'package:licoup/src/contracts/agent_command_runner.dart';
import 'package:licoup/src/contracts/client_conversation_models.dart';

final class ClientConversationController extends ChangeNotifier {
  ClientConversationController({
    required AgentCommandRunner runner,
    ClientConversationService service = const ClientConversationService(),
  }) : _runner = runner,
       _service = service;

  final AgentCommandRunner _runner;
  final ClientConversationService _service;

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

  bool get loading => _loading;
  bool get sending => _sending;
  String get selectedConversationId => _selectedConversationId;
  String get draft => _draft;
  String get failureStage => _failureStage;
  String get failureCode => _failureCode;
  ClientConversation? get selectedConversation => _selectedConversation;
  List<ClientConversationEvent> get events => _events;
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
      _selectedConversationId = normalized;
      _draft = '';
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
    _selectedConversationId = '';
    _selectedConversation = null;
    _events = const [];
    _draft = '';
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
