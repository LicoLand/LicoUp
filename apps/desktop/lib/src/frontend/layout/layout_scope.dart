import 'package:flutter/widgets.dart';

import 'package:flutter_client/src/application/features/layout/layout_state_store.dart';
import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/contracts/presentation/layout_profile.dart';
import 'package:flutter_client/src/contracts/presentation/layout_state_namespace.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/frontend/layout/layout_visual_tokens.dart';

/// Restricts profile state access to the active profile and runtime surface.
final class LayoutScopedState {
  const LayoutScopedState({
    required this.profileId,
    required this.surface,
    required LayoutStateStore store,
  }) : _store = store;

  final LayoutProfileId profileId;
  final LayoutRuntimeSurface surface;
  final LayoutStateStore _store;

  LayoutPresentationStateValue? read({
    required ClientSection destination,
    required String surfaceId,
  }) => _store.read(_namespace(destination, surfaceId));

  void write({
    required ClientSection destination,
    required String surfaceId,
    required LayoutPresentationStateValue value,
  }) => _store.write(_namespace(destination, surfaceId), value);

  void remove({
    required ClientSection destination,
    required String surfaceId,
  }) => _store.remove(_namespace(destination, surfaceId));

  LayoutStateNamespace _namespace(
    ClientSection destination,
    String surfaceId,
  ) => LayoutStateNamespace(
    profileId: profileId,
    surface: surface,
    destination: destination,
    surfaceId: surfaceId,
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
    final scope = context.dependOnInheritedWidgetOfExactType<LayoutScope>();
    if (scope == null) {
      throw StateError('layout_scope_missing');
    }
    return scope;
  }

  @override
  bool updateShouldNotify(LayoutScope oldWidget) =>
      oldWidget.profileId != profileId ||
      oldWidget.environment != environment ||
      oldWidget.restorationNamespace != restorationNamespace ||
      !identical(oldWidget.tokens, tokens) ||
      oldWidget.state.profileId != state.profileId ||
      oldWidget.state.surface != state.surface;
}
