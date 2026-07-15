part of 'package:flutter_client/src/application/controller/client_controller.dart';

mixin _ClientControllerConversationState on ChangeNotifier {
  bool _disposed = false;
  bool _isLoadingMobileConversations = false;

  /// Per-target preparation state: agent IDs currently preparing a new
  /// conversation (no durable session yet). The main-class getter/setter
  /// `_preparingNewConversation` routes through `selectedConversationAgentId`
  /// to prevent cross-agent interference during concurrent feed dispatch.
  final Set<String> _preparingNewConversationTargets = <String>{};
  Map<String, String> _newConversationWorkingDirectories = const {};
  Timer? _conversationActiveRefreshTimer;
  Timer? _conversationBackgroundRefreshTimer;
  final Set<String> _conversationSessionLoadingTargets = <String>{};
  final Set<({String agentId, String sessionId})>
  _conversationActiveRefreshTargets = <({String agentId, String sessionId})>{};
  final Set<String> _conversationBackgroundRefreshTargets = <String>{};
  final Map<String, int> _conversationAppliedRequestSequenceByAgent =
      <String, int>{};
  int _conversationRequestSequence = 0;
  AppLifecycleState _conversationAppLifecycleState = AppLifecycleState.resumed;
  bool _conversationViewFocused = true;
  String _conversationComposerDraft = '';
  final Set<String> _conversationSessionLoadMoreTargets = <String>{};
  Map<String, String> _selectedConversationSessionIdsByAgent = const {};

  final ValueNotifier<int> _appPresentationRevision = ValueNotifier<int>(0);
  final ValueNotifier<int> _conversationStructureRevision = ValueNotifier<int>(
    0,
  );
  final ValueNotifier<int> _activeConversationRevision = ValueNotifier<int>(0);

  ValueListenable<int> get appPresentationListenable =>
      _appPresentationRevision;

  ValueListenable<int> get conversationStructureListenable =>
      _conversationStructureRevision;

  ValueListenable<int> get activeConversationListenable =>
      _activeConversationRevision;

  /// Business-owned draft survives renderer replacement without leaking one
  /// profile's presentation state into another profile.
  String get conversationComposerDraft => _conversationComposerDraft;

  void updateConversationComposerDraft(String value) {
    _conversationComposerDraft = value;
  }

  void _setSelectedConversationSessionIdForAgent(String agentId, String value) {
    if (agentId.trim().isEmpty) {
      return;
    }
    final next = <String, String>{..._selectedConversationSessionIdsByAgent};
    if (value.isEmpty) {
      next.remove(agentId);
    } else {
      next[agentId] = value;
    }
    _selectedConversationSessionIdsByAgent = Map.unmodifiable(next);
  }

  void _notifyStateChanged() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  void _notifyAppPresentationChanged() {
    if (!_disposed) {
      _appPresentationRevision.value += 1;
    }
  }

  void _notifyConversationStructureChanged({bool activeChanged = true}) {
    if (_disposed) {
      return;
    }
    _conversationStructureRevision.value += 1;
    if (activeChanged) {
      _activeConversationRevision.value += 1;
    }
  }

  void _notifyActiveConversationChanged() {
    if (!_disposed) {
      _activeConversationRevision.value += 1;
    }
  }

  @override
  void dispose() {
    _appPresentationRevision.dispose();
    _conversationStructureRevision.dispose();
    _activeConversationRevision.dispose();
    super.dispose();
  }
}
