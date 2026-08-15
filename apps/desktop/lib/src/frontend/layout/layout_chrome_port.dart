import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// The profile-facing runtime boundary for shell chrome.
///
/// Layout renderers receive only immutable semantic state and a pairing
/// intent. Application controllers, services, platform bridges, and concrete
/// profile identities stay behind the shell adapter.
abstract interface class LayoutChromePort
    implements ValueListenable<LayoutChromeSnapshot> {
  Future<void> openPairing(BuildContext context);
  Future<void> openGlobalSearch(BuildContext context);
}

/// Exposes the active shell chrome actions to destination-owned UI without
/// coupling a feature widget to a concrete shell implementation.
final class LayoutChromePortScope extends InheritedWidget {
  const LayoutChromePortScope({
    super.key,
    required this.chrome,
    required super.child,
  });

  final LayoutChromePort chrome;

  static LayoutChromePort? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<LayoutChromePortScope>()
      ?.chrome;

  /// Opens destination-aware global search when chrome is in the tree.
  static Future<void> openSearch(BuildContext context) async {
    final chrome = maybeOf(context);
    if (chrome == null) {
      return;
    }
    await chrome.openGlobalSearch(context);
  }

  @override
  bool updateShouldNotify(LayoutChromePortScope oldWidget) =>
      !identical(oldWidget.chrome, chrome);
}

@immutable
final class LayoutChromeSnapshot {
  const LayoutChromeSnapshot({required this.status});

  const LayoutChromeSnapshot.empty()
    : status = const LayoutChromeStatusSnapshot(message: '', caption: '');

  final LayoutChromeStatusSnapshot status;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LayoutChromeSnapshot && status == other.status;

  @override
  int get hashCode => status.hashCode;
}

@immutable
final class LayoutChromeStatusSnapshot {
  const LayoutChromeStatusSnapshot({
    required this.message,
    required this.caption,
  });

  final String message;
  final String caption;

  String get displayText => message.isEmpty ? caption : message;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LayoutChromeStatusSnapshot &&
          message == other.message &&
          caption == other.caption;

  @override
  int get hashCode => Object.hash(message, caption);
}
