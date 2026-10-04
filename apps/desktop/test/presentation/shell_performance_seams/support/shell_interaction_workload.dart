import 'dart:convert';
import 'dart:io';

import 'shell_seam_fixture.dart';

/// The registered workload definition for the shell's ordinary interactions.
///
/// The definition is data, not code: it names each interaction, the counts the
/// measurement records for it, and the comparison conditions a regression has
/// to violate. It carries no host name, device identifier or path, so the same
/// definition is readable on any development host.
final class ShellInteractionWorkload {
  const ShellInteractionWorkload(this.interactions);

  /// Registered interactions in declaration order.
  final List<ShellInteractionWorkloadEntry> interactions;

  /// Reads the registered definition from the repository root that owns the
  /// running test, walking up from the current directory.
  factory ShellInteractionWorkload.load() {
    var directory = Directory.current;
    while (true) {
      final file = File(
        '${directory.path}/tools/development/performance/'
        'shell-interaction-workloads.json',
      );
      if (file.existsSync()) {
        return ShellInteractionWorkload.parse(
          jsonDecode(file.readAsStringSync()) as Map<String, dynamic>,
        );
      }
      final parent = directory.parent;
      if (parent.path == directory.path) {
        throw StateError(
          'Run from the repository: the registered shell interactions workload '
          'was not found.',
        );
      }
      directory = parent;
    }
  }

  factory ShellInteractionWorkload.parse(Map<String, dynamic> json) {
    if (json['schema'] != 'licoup-shell-interaction-workloads.v1') {
      throw FormatException('Unknown workload schema: ${json['schema']}');
    }
    final conditions = Map<String, dynamic>.from(json['conditions'] as Map);
    final claim = conditions['claim'] as String? ?? '';
    if (!claim.contains('no latency')) {
      throw const FormatException(
        'A counted widget workload must not claim latency or frame duration.',
      );
    }
    final interactions = [
      for (final value in json['interactions'] as List)
        ShellInteractionWorkloadEntry.parse(
          Map<String, dynamic>.from(value as Map),
        ),
    ];
    if (interactions.isEmpty) {
      throw const FormatException('A workload declares at least one action.');
    }
    return ShellInteractionWorkload(interactions);
  }

  ShellInteractionWorkloadEntry entry(String id) =>
      interactions.firstWhere((entry) => entry.id == id);

  bool declares(String id) => interactions.any((entry) => entry.id == id);
}

/// One named ordinary interaction and its counted comparison conditions.
final class ShellInteractionWorkloadEntry {
  const ShellInteractionWorkloadEntry({
    required this.id,
    required this.action,
    required this.measured,
    required this.limits,
    required this.regions,
  });

  final String id;
  final String action;

  /// The counts recorded on the reference host, kept for provenance.
  final Map<String, int> measured;

  /// Largest counted value the interaction may reach before it fails.
  final Map<String, int> limits;

  /// Bounds on rebuilds of a named widget region.
  final List<ShellRegionCondition> regions;

  factory ShellInteractionWorkloadEntry.parse(Map<String, dynamic> json) =>
      ShellInteractionWorkloadEntry(
        id: json['id'] as String,
        action: json['action'] as String,
        measured: _counts(json['measured'], 'measured'),
        limits: _counts(json['limits'], 'limits'),
        regions: [
          for (final value in json['regions'] as List)
            ShellRegionCondition.parse(Map<String, dynamic>.from(value as Map)),
        ],
      );

  /// Every condition the measurement violates.
  List<String> violationsFor(ShellInteractionMeasurement measurement) {
    final violations = <String>[];
    if (measurement.interaction != id) {
      return <String>[
        'measurement ${measurement.interaction} does not belong to $id',
      ];
    }
    void atMost(String metric, int actual) {
      final limit = limits[metric];
      if (limit == null || actual <= limit) return;
      violations.add('$id $metric: $actual > $limit');
    }

    atMost('acceptedProjections', measurement.acceptedProjections);
    atMost('frameConsumedProjections', measurement.frameConsumedProjections);
    atMost('consumedFrames', measurement.consumedFrames);
    atMost('rendererIntents', measurement.rendererIntents);
    atMost('rebuilds', measurement.totalRebuilds);
    for (final region in regions) {
      final actual = measurement.rebuildsMatching(region.widget);
      if (actual < region.min) {
        violations.add('$id region ${region.widget}: $actual < ${region.min}');
      }
      if (actual > region.max) {
        violations.add('$id region ${region.widget}: $actual > ${region.max}');
      }
    }
    return violations;
  }
}

/// Bounds on the rebuilds of one named widget region.
final class ShellRegionCondition {
  const ShellRegionCondition({
    required this.widget,
    required this.min,
    required this.max,
  });

  /// Widget type fragment the region counts.
  final String widget;
  final int min;
  final int max;

  factory ShellRegionCondition.parse(Map<String, dynamic> json) =>
      ShellRegionCondition(
        widget: json['widget'] as String,
        min: json['min'] as int,
        max: json['max'] as int,
      );
}

Map<String, int> _counts(Object? value, String field) => {
  for (final entry in (value as Map).entries)
    entry.key as String: entry.value as int,
};
