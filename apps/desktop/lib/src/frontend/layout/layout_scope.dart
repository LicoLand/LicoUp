import 'package:flutter/widgets.dart';

import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/layout_profile.dart';
import 'package:licoup/src/contracts/presentation/layout_state_namespace.dart';
import 'package:licoup/src/contracts/presentation/layout_state_port.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_visual_tokens.dart';

/// Restricts state access to exactly one profile, surface, and destination.
final class LayoutScopedState {
  const LayoutScopedState({
    required this.profileId,
    required this.surface,
    required this.destination,
    required LayoutStatePort store,
  }) : _store = store;

  final LayoutProfileId profileId;
  final LayoutRuntimeSurface surface;
  final ClientSection destination;
  final LayoutStatePort _store;

  bool declares(LayoutStateChannel channel) =>
      _store.declares(_namespace(channel));

  /// Notifies after any store mutation. Listeners re-read the channels they
  /// care about; writes through any scope (shell or destination) arrive here.
  Stream<void> get changes => _store.changes;
  LayoutStatePort get statePort => _store;

  LayoutPresentationStateValue? readIfDeclared(LayoutStateChannel channel) {
    final namespace = _namespace(channel);
    return _store.declares(namespace) ? _store.read(namespace) : null;
  }

  bool writeIfDeclared(
    LayoutStateChannel channel,
    LayoutPresentationStateValue value,
  ) {
    final namespace = _namespace(channel);
    if (!_store.declares(namespace)) {
      return false;
    }
    _store.write(namespace, value);
    return true;
  }

  /// Reads a channel declared on a sibling destination in this profile.
  ///
  /// Shell chrome that outlives one destination (the shared sidebar column)
  /// uses this to keep one persisted pane extent.
  LayoutPresentationStateValue? readIfDeclaredFor(
    ClientSection destination,
    LayoutStateChannel channel,
  ) {
    final namespace = _namespaceFor(destination, channel);
    return _store.declares(namespace) ? _store.read(namespace) : null;
  }

  /// Writes a channel declared on a sibling destination in this profile.
  bool writeIfDeclaredFor(
    ClientSection destination,
    LayoutStateChannel channel,
    LayoutPresentationStateValue value,
  ) {
    final namespace = _namespaceFor(destination, channel);
    if (!_store.declares(namespace)) {
      return false;
    }
    _store.write(namespace, value);
    return true;
  }

  LayoutPresentationStateValue? read(LayoutStateChannel channel) =>
      _store.read(_namespace(channel));

  void write(LayoutStateChannel channel, LayoutPresentationStateValue value) =>
      _store.write(_namespace(channel), value);

  void remove(LayoutStateChannel channel) => _store.remove(_namespace(channel));

  LayoutStateNamespace _namespace(LayoutStateChannel channel) =>
      _namespaceFor(destination, channel);

  LayoutStateNamespace _namespaceFor(
    ClientSection destination,
    LayoutStateChannel channel,
  ) => LayoutStateNamespace(
    profileId: profileId,
    surface: surface,
    destination: destination,
    channel: channel,
  );
}

final class LayoutScope extends InheritedWidget {
  const LayoutScope({
    super.key,
    required this.profileId,
    required this.environment,
    required this.restorationNamespace,
    required this.tokens,
    required this.state,
    required super.child,
  });

  final LayoutProfileId profileId;
  final LayoutEnvironment environment;
  final String restorationNamespace;
  final LayoutVisualTokens tokens;
  final LayoutScopedState state;

  static LayoutScope of(BuildContext context) {
    final scope = maybeOf(context);
    if (scope == null) {
      throw StateError('layout_scope_missing');
    }
    return scope;
  }

  static LayoutScope? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<LayoutScope>();

  @override
  bool updateShouldNotify(LayoutScope oldWidget) =>
      oldWidget.profileId != profileId ||
      oldWidget.environment != environment ||
      oldWidget.restorationNamespace != restorationNamespace ||
      !identical(oldWidget.tokens, tokens) ||
      oldWidget.state.profileId != state.profileId ||
      oldWidget.state.surface != state.surface ||
      oldWidget.state.destination != state.destination;
}
