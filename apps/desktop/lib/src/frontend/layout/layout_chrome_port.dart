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
