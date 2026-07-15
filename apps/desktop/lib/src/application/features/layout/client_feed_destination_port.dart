import 'package:flutter_client/src/application/controller/client_controller.dart';
import 'package:flutter_client/src/contracts/agent_feed_models.dart';
import 'package:flutter_client/src/contracts/agent_feed_timeline.dart';
import 'package:flutter_client/src/contracts/mobile_agent_account.dart';
import 'package:flutter_client/src/contracts/presentation/destinations/destinations.dart';
import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/contracts/target_candidate.dart';

/// Projects [ClientController] state into the pure Feed destination contract.
final class ClientFeedDestinationPort implements FeedDestinationPort {
  ClientFeedDestinationPort({
    required ClientController controller,
    required LayoutRuntimeSurface surface,
    required ClientSection destination,
  }) : _controller = controller,
       contract = _createContract(surface, destination) {
    final sources = _readSources();
    _snapshot = sources.toSnapshot();
    _sourceTimeline = sources.timeline;
    _visibleTargets = sources.visibleTargets;
    _sourceMobileAgentAccounts = sources.mobileAgentAccounts;
    _controllerScannedTargets = sources.controllerScannedTargets;
    _controllerMobileAgentAccounts = sources.controllerMobileAgentAccounts;
    _controller.addListener(_handleControllerChanged);
  }

  final ClientController _controller;

  @override
  final LayoutDestinationContract<FeedDestinationSnapshot> contract;

  late FeedDestinationSnapshot _snapshot;
  late AgentFeedTimeline _sourceTimeline;
  late List<TargetCandidate> _visibleTargets;
  late List<MobileAgentAccount> _sourceMobileAgentAccounts;
  late List<TargetCandidate> _controllerScannedTargets;
  late List<MobileAgentAccount> _controllerMobileAgentAccounts;
  final Set<_FeedDestinationListenerRegistration> _listeners = {};
  bool _isDisposed = false;

  bool get isDisposed => _isDisposed;

  @override
  FeedDestinationSnapshot get snapshot {
    _ensureOpen();
    return _snapshot;
  }

  @override
  LayoutDestinationSnapshotSubscription listen(
    LayoutDestinationSnapshotListener<FeedDestinationSnapshot> listener, {
    bool emitCurrent = true,
  }) {
    _ensureOpen();
    final registration = _FeedDestinationListenerRegistration(
      owner: this,
      listener: listener,
    );
    _listeners.add(registration);
    if (emitCurrent) {
      try {
        listener(_snapshot);
      } catch (_) {
        registration.cancel();
        rethrow;
      }
    }
    return registration;
  }

  @override
  Future<void> refreshFeedPosts() {
    _ensureOpen();
    return _controller.refreshFeedPosts();
  }

  @override
  Future<void> createUserFeedPost({
    required String body,
    List<String> mentionedAgentIds = const [],
    List<String> attachmentPaths = const [],
  }) {
    _ensureOpen();
    return _controller.createUserFeedPost(
      body: body,
      mentionedAgentIds: List<String>.unmodifiable(mentionedAgentIds),
      attachmentPaths: List<String>.unmodifiable(attachmentPaths),
    );
  }

  @override
  Future<void> addFeedComment(
    String postId,
    String text, {
    String? replyToCommentId,
  }) {
    _ensureOpen();
    return _controller.addFeedComment(
      postId,
      text,
      replyToCommentId: replyToCommentId,
    );
  }

  @override
  Future<void> repostFeedPost(String postId, String toAgentId, {String? note}) {
    _ensureOpen();
    return _controller.repostFeedPost(postId, toAgentId, note: note);
  }

  @override
  Future<void> toggleFollowAuthor(AgentFeedAuthor author) {
    _ensureOpen();
    return _controller.toggleFollowAuthor(author);
  }

  @override
  Future<void> deleteFeedPost(String postId) {
    _ensureOpen();
    return _controller.deleteFeedPost(postId);
  }

  void dispose() {
    if (_isDisposed) {
      return;
    }
    _isDisposed = true;
    _controller.removeListener(_handleControllerChanged);
    for (final registration in List.of(_listeners)) {
      registration.cancel();
    }
  }

  void _handleControllerChanged() {
    if (_isDisposed) {
      return;
    }
    if (identical(_controller.feedTimeline, _sourceTimeline) &&
        identical(_controller.scannedTargets, _controllerScannedTargets) &&
        identical(
          _controller.mobileAgentAccounts,
          _controllerMobileAgentAccounts,
        )) {
      return;
    }
    final sources = _readSources();
    final timelineChanged = !identical(sources.timeline, _sourceTimeline);
    final visibleTargetsChanged = !_sameIdentityList(
      sources.visibleTargets,
      _visibleTargets,
    );
    final mobileAgentAccountsChanged = !_sameIdentityList(
      sources.mobileAgentAccounts,
      _sourceMobileAgentAccounts,
    );
    if (!timelineChanged &&
        !visibleTargetsChanged &&
        !mobileAgentAccountsChanged) {
      _controllerScannedTargets = sources.controllerScannedTargets;
      _controllerMobileAgentAccounts = sources.controllerMobileAgentAccounts;
      return;
    }

    _snapshot = _snapshot.copyWith(
      timeline: timelineChanged ? sources.timeline : null,
      visibleTargets: visibleTargetsChanged ? sources.visibleTargets : null,
      mobileAgentAccounts: mobileAgentAccountsChanged
          ? sources.mobileAgentAccounts
          : null,
    );
    _sourceTimeline = sources.timeline;
    _visibleTargets = sources.visibleTargets;
    _sourceMobileAgentAccounts = sources.mobileAgentAccounts;
    _controllerScannedTargets = sources.controllerScannedTargets;
    _controllerMobileAgentAccounts = sources.controllerMobileAgentAccounts;

    final listeners = List<_FeedDestinationListenerRegistration>.of(_listeners);
    for (final registration in listeners) {
      if (!registration.isCancelled && _listeners.contains(registration)) {
        registration.listener(_snapshot);
      }
    }
  }

  _FeedDestinationSources _readSources() {
    final controllerScannedTargets = _controller.scannedTargets;
    final controllerMobileAgentAccounts = _controller.mobileAgentAccounts;
    final visibleTargets = <TargetCandidate>[
      for (final target in controllerScannedTargets)
        if (target.visibleInClient) target,
    ];
    return _FeedDestinationSources(
      timeline: _controller.feedTimeline,
      visibleTargets: visibleTargets,
      mobileAgentAccounts: [...controllerMobileAgentAccounts],
      controllerScannedTargets: controllerScannedTargets,
      controllerMobileAgentAccounts: controllerMobileAgentAccounts,
    );
  }

  void _cancel(_FeedDestinationListenerRegistration registration) {
    _listeners.remove(registration);
  }

  void _ensureOpen() {
    if (_isDisposed) {
      throw StateError('client_feed_destination_port_disposed');
    }
  }

  static LayoutDestinationContract<FeedDestinationSnapshot> _createContract(
    LayoutRuntimeSurface surface,
    ClientSection destination,
  ) {
    if (destination != ClientSection.feed &&
        destination != ClientSection.controlPanel) {
      throw ArgumentError.value(
        destination,
        'destination',
        'client_feed_destination_port_destination_invalid',
      );
    }
    return LayoutDestinationContract<FeedDestinationSnapshot>(
      key: LayoutDestinationContractKey(
        surface: surface,
        destination: destination,
      ),
    );
  }
}

final class _FeedDestinationSources {
  const _FeedDestinationSources({
    required this.timeline,
    required this.visibleTargets,
    required this.mobileAgentAccounts,
    required this.controllerScannedTargets,
    required this.controllerMobileAgentAccounts,
  });

  final AgentFeedTimeline timeline;
  final List<TargetCandidate> visibleTargets;
  final List<MobileAgentAccount> mobileAgentAccounts;
  final List<TargetCandidate> controllerScannedTargets;
  final List<MobileAgentAccount> controllerMobileAgentAccounts;

  FeedDestinationSnapshot toSnapshot() {
    return FeedDestinationSnapshot(
      timeline: timeline,
      visibleTargets: visibleTargets,
      mobileAgentAccounts: mobileAgentAccounts,
    );
  }
}

final class _FeedDestinationListenerRegistration
    implements LayoutDestinationSnapshotSubscription {
  _FeedDestinationListenerRegistration({
    required ClientFeedDestinationPort owner,
    required this.listener,
  }) : _owner = owner;

  final ClientFeedDestinationPort _owner;
  final LayoutDestinationSnapshotListener<FeedDestinationSnapshot> listener;
  bool _isCancelled = false;

  @override
  bool get isCancelled => _isCancelled;

  @override
  void cancel() {
    if (_isCancelled) {
      return;
    }
    _isCancelled = true;
    _owner._cancel(this);
  }
}

bool _sameIdentityList<T extends Object>(List<T> left, List<T> right) {
  if (left.length != right.length) {
    return false;
  }
  for (var index = 0; index < left.length; index += 1) {
    if (!identical(left[index], right[index])) {
      return false;
    }
  }
  return true;
}
