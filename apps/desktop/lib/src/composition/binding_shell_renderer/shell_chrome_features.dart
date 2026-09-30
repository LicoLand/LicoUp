import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_runtime/presentation_runtime.dart';

import 'package:licoup/src/composition/binding_shell_renderer/shell_dock_composer.dart';
import 'package:licoup/src/frontend/environment/environment_projection_adapter.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_display_names.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_search_palette.dart';
import 'package:licoup/src/frontend/features/mobile_relay/ui/mobile_relay_panel.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_features.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_port.dart';
import 'package:licoup/src/frontend/shared/ui/lico_toast.dart';
import 'package:licoup/src/presentation/agents/agents_binding.dart';
import 'package:licoup/src/presentation/chrome/chrome_projection.dart';
import 'package:licoup/src/presentation/conversation/conversation_binding.dart';
import 'package:licoup/src/presentation/conversation/conversation_intent.dart';
import 'package:licoup/src/presentation/environment/environment_projection.dart';
import 'package:licoup/src/presentation/mobile_relay/mobile_relay_binding.dart';
import 'package:licoup/src/presentation/search/search_binding.dart';
import 'package:licoup/src/presentation/shell/shell_projection.dart';

final class ShellChromeFeatures implements LayoutChromeFeatures {
  ShellChromeFeatures({
    required PresentationRuntime runtime,
    required PresentationSource<ChromeProjection> chromeSource,
    required this.agents,
    required this.conversation,
    required this.auxChromePanelOpen,
  }) : notificationNotices = _ChromeNoticesListenable(
         runtime: runtime,
         source: chromeSource,
       );

  final AgentsBinding agents;
  final ConversationBinding conversation;

  @override
  final ValueListenable<LicoToastNoticesSnapshot> notificationNotices;

  @override
  final ValueNotifier<bool> auxChromePanelOpen;

  @override
  Widget buildDockComposer(BuildContext context, {bool expanded = false}) =>
      DockConversationComposer(
        agents: agents,
        conversation: conversation,
        expanded: expanded,
      );

  @override
  void activateOperationNotice(ChromeOperationNotificationProjection notice) {
    final target = notice.completionTarget;
    if (target == null) return;
    conversation.intents.send(
      ActivateContinuityCompletionNotice(notificationId: target.notificationId),
    );
  }
}

/// Maps the runtime-backed chrome source to the toast notices snapshot.
///
/// One subscription per attached listener observes the source through the
/// application-scope runtime, so the exposure owns no persistent subscription
/// of its own and the value is seeded from the already-admitted snapshot when
/// one exists. A revoked or failing source clears the snapshot instead of
/// re-serving the withdrawn value.
final class _ChromeNoticesListenable
    implements ValueListenable<LicoToastNoticesSnapshot> {
  _ChromeNoticesListenable({required this.runtime, required this.source});

  final PresentationRuntime runtime;
  final PresentationSource<ChromeProjection> source;
  final Map<VoidCallback, _ChromeNoticesSubscription> _subscriptions =
      <VoidCallback, _ChromeNoticesSubscription>{};
  LicoToastNoticesSnapshot _value = const LicoToastNoticesSnapshot();
  bool _seeded = false;

  @override
  LicoToastNoticesSnapshot get value {
    _seedFromRuntime();
    return _value;
  }

  @override
  void addListener(VoidCallback listener) {
    if (_subscriptions.containsKey(listener)) return;
    _seedFromRuntime();
    _subscriptions[listener] = _observe(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    final subscription = _subscriptions.remove(listener);
    if (subscription == null) return;
    unawaited(subscription.cancel());
  }

  void _seedFromRuntime() {
    if (_seeded) return;
    _seeded = true;
    final admitted = runtime.current(source.fieldGroup);
    if (admitted != null) _value = _snapshot(admitted.value);
  }

  _ChromeNoticesSubscription _observe(VoidCallback listener) {
    final observation = runtime.observe(source);
    final subscription = observation.stream.listen(
      (snapshot) {
        _value = _snapshot(snapshot.value);
        listener();
      },
      onError: (Object error, StackTrace stack) {
        // Authority withdrawal and source failure both make the withdrawn
        // notices invisible; the next admitted snapshot republishes.
        _value = const LicoToastNoticesSnapshot();
        listener();
      },
    );
    return _ChromeNoticesSubscription(observation, subscription);
  }

  static LicoToastNoticesSnapshot _snapshot(ChromeProjection projection) {
    final operationNotices = projection.operationNotifications.isNotEmpty
        ? projection.operationNotifications
        : [
            for (final notice in projection.notifications)
              ChromeOperationNotificationProjection(
                id: notice.id,
                messageChinese: notice.message,
                messageEnglish: notice.message,
                severity: notice.severity,
                reasonCode: notice.reasonCode,
              ),
          ];
    return LicoToastNoticesSnapshot(
      operationNotices: operationNotices,
      agentNotices: [
        for (final notice in projection.agentNotifications)
          LicoToastAgentNotice(
            id: notice.target.id,
            displayName: agentConversationTargetDisplayName(notice.target),
            activity: notice.activity,
          ),
      ],
      gatewayNotice: projection.gatewayNotification,
      operationRevision: projection.operationAutoRevealRevision,
      gatewayRevision: projection.gatewayAutoRevealRevision,
    );
  }
}

final class _ChromeNoticesSubscription {
  _ChromeNoticesSubscription(this._observation, this._streamSubscription);

  final ResourceObservationSubscription<ChromeProjection> _observation;
  final StreamSubscription<ResourceSnapshot<ChromeProjection>>
  _streamSubscription;

  Future<void> cancel() async {
    await _streamSubscription.cancel();
    await _observation.close();
  }
}

/// Shell chrome status/locale fed by the runtime-backed shell sources.
///
/// Seeded from the already-admitted snapshots when they exist, then advanced
/// only by admitted source changes. A revoked or failing region clears the
/// status instead of falling back to the raw projection owner.
final class ShellLayoutChrome implements LayoutChromePort {
  ShellLayoutChrome({
    required PresentationRuntime runtime,
    required PresentationSource<StatusProjection> status,
    required PresentationSource<LocaleProjection> locale,
    required MobileRelayBinding? mobileRelay,
    required SearchBinding? search,
  }) : _mobileRelay = mobileRelay,
       _search = search {
    _status = runtime.current(status.fieldGroup)?.value;
    _locale = runtime.current(locale.fieldGroup)?.value;
    _value = _compose();
    final statusObservation = runtime.observe(status);
    _statusSubscription = statusObservation.stream.listen(
      (snapshot) {
        _status = snapshot.value;
        _publish();
      },
      onError: (Object error, StackTrace stack) {
        _status = null;
        _publish();
      },
    );
    final localeObservation = runtime.observe(locale);
    _localeSubscription = localeObservation.stream.listen(
      (snapshot) {
        _locale = snapshot.value;
        _publish();
      },
      onError: (Object error, StackTrace stack) {
        _locale = null;
        _publish();
      },
    );
    _statusObservation = statusObservation;
    _localeObservation = localeObservation;
  }

  final MobileRelayBinding? _mobileRelay;
  final SearchBinding? _search;
  final _RendererNotifier _listeners = _RendererNotifier();
  StatusProjection? _status;
  LocaleProjection? _locale;
  late final ResourceObservationSubscription<StatusProjection>
  _statusObservation;
  late final ResourceObservationSubscription<LocaleProjection>
  _localeObservation;
  late final StreamSubscription<ResourceSnapshot<StatusProjection>>
  _statusSubscription;
  late final StreamSubscription<ResourceSnapshot<LocaleProjection>>
  _localeSubscription;
  late LayoutChromeSnapshot _value;
  bool _disposed = false;

  @override
  LayoutChromeSnapshot get value => _value;

  @override
  void addListener(VoidCallback listener) => _listeners.addListener(listener);

  @override
  void removeListener(VoidCallback listener) =>
      _listeners.removeListener(listener);

  /// Opens the pairing entry only when the relay feature is installed; an
  /// absent relay binding has no pairing surface and no owner to reach.
  @override
  Future<void> openPairing(BuildContext context) {
    final mobileRelay = _mobileRelay;
    return mobileRelay == null
        ? Future<void>.value()
        : showMobileRelayPopup(context, mobileRelay);
  }

  /// Opens global search only when the search feature is installed; an absent
  /// search binding has no search surface and no owner to reach.
  @override
  Future<void> openGlobalSearch(BuildContext context) {
    final search = _search;
    return search == null
        ? Future<void>.value()
        : showAgentConversationSearchPalette(context, search);
  }

  LayoutChromeSnapshot _compose() {
    final status = _status;
    final locale = _locale;
    if (status == null || locale == null) {
      return const LayoutChromeSnapshot.empty();
    }
    return _snapshot(status, locale);
  }

  void _publish() {
    if (_disposed) return;
    final next = _compose();
    if (next == _value) return;
    _value = next;
    _listeners.publish();
  }

  static LayoutChromeSnapshot _snapshot(
    StatusProjection projection,
    LocaleProjection locale,
  ) {
    final resolved = resolveStatusProjection(projection, locale);
    return LayoutChromeSnapshot(
      status: LayoutChromeStatusSnapshot(
        message: resolved.message,
        caption: resolved.caption,
        errorCode: resolved.errorCode,
      ),
    );
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await Future.wait([
      _statusSubscription.cancel(),
      _localeSubscription.cancel(),
    ]);
    await Future.wait([_statusObservation.close(), _localeObservation.close()]);
    _listeners.dispose();
  }
}

final class _RendererNotifier extends ChangeNotifier {
  void publish() => notifyListeners();
}
