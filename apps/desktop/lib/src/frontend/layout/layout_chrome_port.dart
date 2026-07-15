import 'dart:collection';

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
}

@immutable
final class LayoutChromeSnapshot {
  const LayoutChromeSnapshot({required this.status, this.allowance});

  const LayoutChromeSnapshot.empty()
    : status = const LayoutChromeStatusSnapshot(message: '', caption: ''),
      allowance = null;

  final LayoutChromeStatusSnapshot status;
  final LayoutChromeAllowanceSnapshot? allowance;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LayoutChromeSnapshot &&
          status == other.status &&
          allowance == other.allowance;

  @override
  int get hashCode => Object.hash(status, allowance);
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

@immutable
final class LayoutChromeAllowanceSnapshot {
  LayoutChromeAllowanceSnapshot({
    required this.targetId,
    required this.targetLabel,
    required Iterable<LayoutChromeAllowanceMeterSnapshot> meters,
    required this.totalTokens,
    required this.targetTokens,
  }) : meters = UnmodifiableListView(
         List<LayoutChromeAllowanceMeterSnapshot>.of(meters),
       );

  final String targetId;
  final String targetLabel;
  final List<LayoutChromeAllowanceMeterSnapshot> meters;
  final int totalTokens;
  final int? targetTokens;

  int? get usagePercentage {
    final usageTokens = targetTokens;
    if (totalTokens <= 0 || usageTokens == null) {
      return null;
    }
    return ((usageTokens / totalTokens) * 100).clamp(0, 999).round();
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LayoutChromeAllowanceSnapshot &&
          targetId == other.targetId &&
          targetLabel == other.targetLabel &&
          totalTokens == other.totalTokens &&
          targetTokens == other.targetTokens &&
          listEquals(meters, other.meters);

  @override
  int get hashCode => Object.hash(
    targetId,
    targetLabel,
    totalTokens,
    targetTokens,
    Object.hashAll(meters),
  );
}

/// Raw semantic meter data required to preserve the existing allowance
/// presentation. Profiles decide how to style it without importing usage
/// domain models.
@immutable
final class LayoutChromeAllowanceMeterSnapshot {
  const LayoutChromeAllowanceMeterSnapshot({
    required this.kind,
    required this.label,
    required this.provider,
    required this.period,
    required this.status,
    required this.value,
    required this.unit,
    required this.message,
  });

  final String kind;
  final String label;
  final String provider;
  final String period;
  final String status;
  final String value;
  final String unit;
  final String message;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LayoutChromeAllowanceMeterSnapshot &&
          kind == other.kind &&
          label == other.label &&
          provider == other.provider &&
          period == other.period &&
          status == other.status &&
          value == other.value &&
          unit == other.unit &&
          message == other.message;

  @override
  int get hashCode =>
      Object.hash(kind, label, provider, period, status, value, unit, message);
}
