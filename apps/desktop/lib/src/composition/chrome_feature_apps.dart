import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/contracts/collaboration_run_models.dart';
import 'package:licoup/src/contracts/plugin_window_host_models.dart';
import 'package:licoup/src/frontend/features/collaboration/ui/collaboration_flowchart_view.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_features.dart';
import 'package:licoup/src/frontend/shared/ui/lico_empty_state.dart';
import 'package:licoup/src/presentation/collaboration/collaboration_binding.dart';
import 'package:licoup/src/presentation/collaboration/collaboration_projection.dart';
import 'package:licoup/src/presentation/conversation/conversation_binding.dart';
import 'package:licoup/src/presentation/conversation/conversation_projection.dart';
import 'package:licoup/src/presentation/plugin_window/plugin_window_projection.dart';

typedef CollaborationBindingFor =
    CollaborationBinding Function(String conversationId);
typedef CollaborationBindingRelease =
    Future<void> Function(String conversationId);

/// Follows the selected group conversation for the Collaboration app.
///
/// Active only while someone listens: the first listener starts observing
/// the conversation and retains that conversation's collaboration binding;
/// the last listener leaving releases it. Switching conversations releases
/// the previous binding.
final class CollaborationAppFollower
    implements ValueListenable<LayoutCollaborationAppState> {
  CollaborationAppFollower({
    required ConversationBinding conversation,
    required CollaborationBindingFor bindingFor,
    required CollaborationBindingRelease release,
  }) : _conversation = conversation,
       _bindingFor = bindingFor,
       _release = release;

  final ConversationBinding _conversation;
  final CollaborationBindingFor _bindingFor;
  final CollaborationBindingRelease _release;
  final _FollowerNotifier _notifier = _FollowerNotifier();
  final Map<VoidCallback, int> _registrations = <VoidCallback, int>{};
  int _listeners = 0;

  StreamSubscription<ProjectionUpdate<ConversationProjection>>? _root;
  StreamSubscription<ProjectionUpdate<CanonicalConversationProjection>>?
  _canonical;
  StreamSubscription<ProjectionUpdate<CollaborationProjection>>? _run;

  String _conversationId = '';
  CollaborationBinding? _binding;
  LayoutCollaborationAppState _value = const LayoutCollaborationAppState();

  /// The followed conversation; empty when no group conversation is
  /// selected.
  String get conversationId => _conversationId;

  /// The binding of [conversationId]; null when none is followed or nobody
  /// listens.
  CollaborationBinding? get binding => _binding;

  @override
  LayoutCollaborationAppState get value => _value;

  @override
  void addListener(VoidCallback listener) {
    _notifier.addListener(listener);
    _registrations.update(listener, (count) => count + 1, ifAbsent: () => 1);
    _listeners += 1;
    if (_listeners == 1) _start();
  }

  @override
  void removeListener(VoidCallback listener) {
    final count = _registrations[listener];
    if (count == null) return;
    _notifier.removeListener(listener);
    if (count == 1) {
      _registrations.remove(listener);
    } else {
      _registrations[listener] = count - 1;
    }
    _listeners -= 1;
    if (_listeners == 0) _stop();
  }

  void _start() {
    _root = _conversation.projection.changes.listen((_) => _sync());
    _canonical = _conversation.canonicalEvents.changes.listen((_) => _sync());
    _sync(notify: false);
  }

  void _stop() {
    unawaited(_root?.cancel());
    unawaited(_canonical?.cancel());
    _root = null;
    _canonical = null;
    _follow('');
  }

  void _sync({bool notify = true}) {
    final root = _conversation.projection.current;
    final canonical = _conversation.canonicalEvents.current;
    final id = root.authority == ConversationAuthority.canonicalConversation
        ? root.conversationId.trim()
        : '';
    final changed = _follow(id);
    final title = id.isEmpty || canonical.conversationId != id
        ? ''
        : canonical.conversation?.title.trim() ?? '';
    final next = LayoutCollaborationAppState(
      subtitle: title,
      pendingDecisions: _pending(_binding?.projection.current),
    );
    if (next == _value && !changed) return;
    _value = next;
    if (notify) _notifier.publish();
  }

  /// Retains the binding of [id] and releases the previous one. Returns
  /// whether the followed conversation changed.
  bool _follow(String id) {
    if (id == _conversationId) return false;
    final previous = _conversationId;
    unawaited(_run?.cancel());
    _run = null;
    _conversationId = id;
    _binding = id.isEmpty ? null : _bindingFor(id);
    _run = _binding?.projection.changes.listen((_) => _sync());
    if (previous.isNotEmpty) unawaited(_release(previous));
    return true;
  }

  static int _pending(CollaborationProjection? projection) {
    if (projection == null || !projection.isActive) return 0;
    var count = projection.proposal == null ? 0 : 1;
    for (final state in projection.nodeStates.values) {
      if (state.status == CollaborationNodeStatus.waitingUser) count += 1;
    }
    return count;
  }
}

final class _FollowerNotifier extends ChangeNotifier {
  void publish() => notifyListeners();
}

/// The Collaboration app surface: the flowchart of the followed
/// conversation, or a prompt to select a group conversation.
final class CollaborationAppSurface extends StatefulWidget {
  const CollaborationAppSurface({super.key, required this.follower});

  final CollaborationAppFollower follower;

  @override
  State<CollaborationAppSurface> createState() =>
      _CollaborationAppSurfaceState();
}

final class _CollaborationAppSurfaceState
    extends State<CollaborationAppSurface> {
  @override
  void initState() {
    super.initState();
    widget.follower.addListener(_changed);
  }

  @override
  void didUpdateWidget(CollaborationAppSurface oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (identical(oldWidget.follower, widget.follower)) return;
    oldWidget.follower.removeListener(_changed);
    widget.follower.addListener(_changed);
  }

  @override
  void dispose() {
    widget.follower.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    final binding = widget.follower.binding;
    if (binding == null) {
      return LicoEmptyState(
        key: const Key('collaboration-app-no-conversation'),
        icon: Icons.account_tree_outlined,
        title: strings.collaborationNoGroupSelected,
        message: strings.collaborationNoGroupSelectedMessage,
      );
    }
    return CollaborationFlowchartView(
      key: ValueKey<String>(
        'collaboration-app-${widget.follower.conversationId}',
      ),
      binding: binding,
    );
  }
}

/// Installed UI plugins as chrome summaries, mapped from the plugin window
/// projection on demand; listeners subscribe straight to its change stream.
final class PluginWindowSummaries
    implements ValueListenable<List<LayoutPluginWindowSummary>> {
  PluginWindowSummaries({required this.projection});

  final ProjectionSource<PluginWindowProjection> projection;
  final Map<
    VoidCallback,
    StreamSubscription<ProjectionUpdate<PluginWindowProjection>>
  >
  _subscriptions = {};
  PluginWindowProjection? _mapped;
  List<LayoutPluginWindowSummary> _value = const [];

  @override
  List<LayoutPluginWindowSummary> get value {
    final current = projection.current;
    if (identical(current, _mapped)) return _value;
    final next = [
      for (final manifest in current.catalog)
        LayoutPluginWindowSummary(
          id: manifest.id,
          name: manifest.name,
          official: manifest.publisher == PluginPublisher.official,
          open: current.session(manifest.id) != null,
        ),
    ];
    _mapped = current;
    if (!listEquals(next, _value)) _value = List.unmodifiable(next);
    return _value;
  }

  @override
  void addListener(VoidCallback listener) {
    if (_subscriptions.containsKey(listener)) return;
    _subscriptions[listener] = projection.changes.listen((_) => listener());
  }

  @override
  void removeListener(VoidCallback listener) {
    final subscription = _subscriptions.remove(listener);
    if (subscription != null) unawaited(subscription.cancel());
  }
}
