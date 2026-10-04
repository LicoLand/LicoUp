import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'support/shell_interaction_workload.dart';

/// The registered workload definition is data the measured suites read.
///
/// It has to name the counted conditions for every measured interaction,
/// justify each budget from a recorded measurement, and stay free of host
/// identifiers so the definition is portable between development machines.
void main() {
  final workload = ShellInteractionWorkload.load();

  test('every counted metric has a declared limit and a measured value', () {
    const countedMetrics = <String>[
      'acceptedProjections',
      'frameConsumedProjections',
      'consumedFrames',
      'rendererIntents',
      'rebuilds',
    ];
    for (final entry in workload.interactions) {
      expect(entry.action, isNotEmpty, reason: '${entry.id} names its action');
      for (final metric in countedMetrics) {
        expect(
          entry.limits[metric],
          isNotNull,
          reason: '${entry.id} declares a $metric limit',
        );
        expect(
          entry.measured[metric],
          isNotNull,
          reason: '${entry.id} records the measured $metric',
        );
        expect(
          entry.measured[metric]!,
          lessThanOrEqualTo(entry.limits[metric]!),
          reason:
              '${entry.id} budget for $metric is justified by its measurement',
        );
      }
      expect(
        entry.regions,
        isNotEmpty,
        reason: '${entry.id} names the region that owns its response',
      );
      for (final region in entry.regions) {
        expect(region.min, lessThanOrEqualTo(region.max));
      }
    }
  });

  test('the definition declares a counted claim and no host identity', () {
    final file = File(
      '${_repositoryRoot()}/tools/development/performance/'
      'shell-interaction-workloads.json',
    );
    final source = file.readAsStringSync();
    final json = jsonDecode(source) as Map<String, dynamic>;
    final conditions = Map<String, dynamic>.from(json['conditions'] as Map);
    expect(
      conditions['clock'],
      contains('virtual widget clock'),
      reason: 'counted widget work is not an engine frame measurement',
    );
    expect(
      conditions['engineFrames'],
      contains('client:test:ui'),
      reason: 'real engine frames stay with the profile harness',
    );
    for (final forbidden in <String>[
      '/Users/',
      '/home/',
      'C:\\\\',
      'hostname',
      'serial',
      'udid',
    ]) {
      expect(
        source.contains(forbidden),
        isFalse,
        reason:
            'the workload definition must not identify a machine ($forbidden)',
      );
    }
    final evidence = (conditions['evidence'] as List).cast<String>();
    expect(
      evidence,
      isNotEmpty,
      reason: 'the definition points at the suites that measure it',
    );
    for (final suite in evidence) {
      expect(
        File('${_repositoryRoot()}/$suite').existsSync(),
        isTrue,
        reason: 'the definition names $suite, which has to exist',
      );
    }
  });
}

String _repositoryRoot() {
  var directory = Directory.current;
  while (true) {
    if (File(
      '${directory.path}/tools/development/performance/'
      'shell-interaction-workloads.json',
    ).existsSync()) {
      return directory.path;
    }
    final parent = directory.parent;
    if (parent.path == directory.path) {
      throw StateError('Run from the repository that owns the workload.');
    }
    directory = parent;
  }
}
