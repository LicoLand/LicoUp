import 'package:flutter/foundation.dart';

import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';

typedef ClientNavigationHook = void Function();

final class ClientSectionHooks {
  const ClientSectionHooks({this.onEnter, this.onExit, this.onReselect});

  final ClientNavigationHook? onEnter;
  final ClientNavigationHook? onExit;
  final ClientNavigationHook? onReselect;
}

/// Owns section aliasing, runtime-surface policy, and section lifecycle hooks.
/// Feature-specific work is injected rather than coupled to ClientController.
final class ClientNavigationController extends ChangeNotifier {
  ClientNavigationController({
    required bool Function() isMobileRuntime,
    Map<ClientSection, ClientSectionHooks> hooks = const {},
    ClientSection initialSection = ClientSection.agents,
  }) : _isMobileRuntime = isMobileRuntime,
       _hooks = Map.unmodifiable(hooks),
       _currentSection = initialSection;

  final bool Function() _isMobileRuntime;
  final Map<ClientSection, ClientSectionHooks> _hooks;
  ClientSection _currentSection;

  ClientSection get currentSection => _currentSection;

  /// Replaces restored presentation state without firing feature hooks.
  void replaceCurrentSection(ClientSection value) {
    final next = resolve(value);
    if (_currentSection == next) return;
    _currentSection = next;
    notifyListeners();
  }

  ClientSection resolve(ClientSection requested) {
    if (!_isMobileRuntime()) {
      return requested;
    }
    return switch (requested) {
      ClientSection.agents ||
      ClientSection.mobileRelay ||
      ClientSection.settings => requested,
      _ => ClientSection.agents,
    };
  }

  bool select(ClientSection requested) {
    final next = resolve(requested);
    if (next == _currentSection) {
      _hooks[next]?.onReselect?.call();
      return false;
    }
    final previous = _currentSection;
    _hooks[previous]?.onExit?.call();
    _currentSection = next;
    _hooks[next]?.onEnter?.call();
    notifyListeners();
    return true;
  }
}
