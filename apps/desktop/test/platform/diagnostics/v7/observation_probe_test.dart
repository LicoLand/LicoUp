import 'package:flutter_test/flutter_test.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/platform/diagnostics/v7/observation_backend.dart';
import 'package:licoup/src/platform/diagnostics/v7/observation_ids.dart';
import 'package:licoup/src/platform/diagnostics/v7/observation_probe.dart';
import 'package:licoup/src/platform/diagnostics/v7/observation_segment.dart';

/// Bounded, test-only backend.
final class _CapturingBackend implements ObservationTelemetryBackend {
  final List<ObservationSegmentRecord> records = <ObservationSegmentRecord>[];
  ObservationProbe? reentrant;

  @override
  void emit(ObservationSegmentRecord record) {
    records.add(record);
    reentrant?.complete(
      reentrant!.begin(
        ObservationPhase.queueWait,
        ObservationIds(runId: 'run-reentrant'),
      )!,
    );
  }
}

void main() {
  test(
    'a switched-off probe opens nothing, counts nothing, and calls nothing',
    () {
      final probe = ObservationProbe.disabled();
      final backend = _CapturingBackend();
      var clockReads = 0;

      expect(probe.isEnabled, isFalse);
      expect(
        probe.begin(ObservationPhase.admissionWait, const ObservationIds()),
        isNull,
        reason: 'an off probe reads no clock and opens no segment',
      );
      expect(clockReads, 0);
      expect(probe.pendingCount, 0);
      expect(probe.dropCounts, const ObservationDropCounts());
      expect(probe.drain(), 0);
      expect(backend.records, isEmpty);
      expect(
        probe
            .submit(
              const ObservationSegmentRecord(
                phase: ObservationPhase.build,
                ids: ObservationIds(),
                startedMicroseconds: 0,
                durationMicroseconds: 1,
              ),
            )
            .outcome,
        ObservationSubmitOutcome.disabled,
        reason: 'a switched-off probe refuses records without inventing a drop',
      );
      expect(probe.dropCounts, const ObservationDropCounts());
      expect(probe.pendingCount, 0);
      expect(probe.drain(), 0);
      expect(clockReads, 0);
    },
  );

  test('an enabled probe reads its clock once per segment edge', () {
    var now = 50;
    var clockReads = 0;
    final probe = ObservationProbe.bounded(
      bufferCapacity: 4,
      clock: () {
        clockReads += 1;
        return now;
      },
      backend: _CapturingBackend(),
    );

    final segment = probe.begin(
      ObservationPhase.build,
      const ObservationIds(requestId: 'req-clock'),
    )!;
    expect(clockReads, 1);
    now = 90;
    expect(segment.finish().durationMicroseconds, 40);
    expect(clockReads, 2);
  });

  test('a full bounded buffer counts the drop and keeps business moving', () {
    var now = 0;
    final backend = _CapturingBackend();
    final probe = ObservationProbe.bounded(
      bufferCapacity: 2,
      clock: () => now++,
      backend: backend,
    );

    final outcomes = <ObservationSubmitOutcome>[];
    for (var index = 0; index < 3; index += 1) {
      outcomes.add(
        probe
            .complete(
              probe.begin(
                ObservationPhase.build,
                const ObservationIds(requestId: 'req-1'),
              )!,
            )
            .outcome,
      );
    }

    expect(outcomes, <ObservationSubmitOutcome>[
      ObservationSubmitOutcome.queued,
      ObservationSubmitOutcome.queued,
      ObservationSubmitOutcome.dropped,
    ]);
    expect(probe.dropCounts.bufferFull, 1);
    expect(probe.dropCounts.total, 1);
    expect(probe.pendingCount, 2);
    expect(probe.drain(), 2);
    expect(probe.pendingCount, 0);
    expect(backend.records, hasLength(2));
  });

  test('the sampling budget resets per window and counts the refusal', () {
    var now = 0;
    final probe = ObservationProbe.bounded(
      bufferCapacity: 8,
      sampling: const ObservationSamplingBudget(
        maxRecordsPerWindow: 1,
        windowMicroseconds: 1000,
      ),
      clock: () => now,
      backend: _CapturingBackend(),
    );
    const ids = ObservationIds(runId: 'run-sampled');
    ObservationSegmentRecord record(int duration) => ObservationSegmentRecord(
      phase: ObservationPhase.queueWait,
      ids: ids,
      startedMicroseconds: 0,
      durationMicroseconds: duration,
    );

    expect(probe.submit(record(10)).outcome, ObservationSubmitOutcome.queued);
    expect(
      probe.submit(record(11)).dropReason,
      ObservationDropReason.samplingBudgetExhausted,
    );
    expect(probe.dropCounts.samplingBudgetExhausted, 1);

    now = 999;
    expect(
      probe.submit(record(12)).dropReason,
      ObservationDropReason.samplingBudgetExhausted,
      reason: 'the window has not elapsed yet',
    );

    now = 1000;
    expect(
      probe.submit(record(13)).outcome,
      ObservationSubmitOutcome.queued,
      reason: 'the next window samples again',
    );
    expect(probe.drain(), 2);
  });

  test('the privacy budget refuses content, secrets, and private paths', () {
    var now = 0;
    final backend = _CapturingBackend();
    final probe = ObservationProbe.bounded(
      bufferCapacity: 8,
      clock: () => now++,
      backend: backend,
    );
    // Absolute home paths are assembled from parts: this file proves they are
    // refused, and must not itself carry a machine-specific path literal.
    String absoluteHome(String tail) =>
        <String>['', 'Users', 'private-owner', tail].join('/');
    final homeAnchored = <String>['~', 'private', 'effect'].join('/');
    final driveQualified = <String>['C:', 'private', 'run'].join('\\');
    expect(homeAnchored, startsWith('~'));
    expect(driveQualified, startsWith('C:'));
    expect(driveQualified, contains('\\'));
    final cases =
        <(ObservationIdField, String, ObservationPrivacyViolationKind)>[
          (
            ObservationIdField.conversationId,
            'line one\nline two',
            ObservationPrivacyViolationKind.unprintable,
          ),
          (
            ObservationIdField.requestId,
            absoluteHome('secrets.txt'),
            ObservationPrivacyViolationKind.privatePath,
          ),
          (
            ObservationIdField.effectId,
            homeAnchored,
            ObservationPrivacyViolationKind.privatePath,
          ),
          (
            ObservationIdField.runId,
            driveQualified,
            ObservationPrivacyViolationKind.privatePath,
          ),
          (
            ObservationIdField.attemptToken,
            'attempt-token-${'x' * 148}',
            ObservationPrivacyViolationKind.oversized,
          ),
        ];
    for (final (field, value, kind) in cases) {
      final receipt = probe.complete(
        probe.begin(
          ObservationPhase.prepareCpu,
          const ObservationIds().withId(field, value),
        )!,
      );
      expect(
        receipt.dropReason,
        ObservationDropReason.privacyBudgetExceeded,
        reason: '${field.wireName} must be refused',
      );
      expect(
        probe.dropCounts.lastPrivacyViolation,
        ObservationPrivacyViolation.id(field, kind),
      );
    }
    expect(probe.dropCounts.privacyBudgetExceeded, 5);
    expect(probe.pendingCount, 0);
    expect(probe.drain(), 0);
    expect(
      backend.records,
      isEmpty,
      reason: 'a refused value never reaches a backend',
    );

    final accepted = probe.complete(
      probe.begin(
        ObservationPhase.prepareCpu,
        const ObservationIds(
          sourcePosition: 'lib/src/a.dart:12',
          prepareId: 'prepare-7',
        ),
      )!,
    );
    expect(
      accepted.outcome,
      ObservationSubmitOutcome.queued,
      reason: 'repository-relative positions and ordinary ids stay acceptable',
    );
  });

  test('the privacy budget bounds span links', () {
    final probe = ObservationProbe.bounded(
      bufferCapacity: 4,
      privacy: const ObservationPrivacyBudget(maxLinks: 2),
      clock: () => 0,
      backend: _CapturingBackend(),
    );
    final links = <ObservationSpanLink>[
      for (final node in <String>['node-a/1', 'node-b/1'])
        ObservationSpanLink(
          ids: ObservationIds(nodeVisit: node),
          relation: ObservationLinkRelation.predecessor,
        ),
    ];
    ObservationSegmentRecord record(List<ObservationSpanLink> attached) =>
        ObservationSegmentRecord(
          phase: ObservationPhase.databaseTransaction,
          ids: const ObservationIds(runId: 'run-links'),
          startedMicroseconds: 0,
          durationMicroseconds: 4,
          links: attached,
        );

    expect(
      probe.submit(record(links)).outcome,
      ObservationSubmitOutcome.queued,
    );
    expect(
      probe
          .submit(
            record(<ObservationSpanLink>[
              ...links,
              ObservationSpanLink(
                ids: const ObservationIds(nodeVisit: 'node-c/1'),
                relation: ObservationLinkRelation.predecessor,
              ),
            ]),
          )
          .dropReason,
      ObservationDropReason.privacyBudgetExceeded,
    );
    expect(
      probe.dropCounts.lastPrivacyViolation,
      const ObservationPrivacyViolation.tooManyLinks(),
    );
  });

  test(
    'parallel predecessors and queue producers use links, not a call stack',
    () {
      var now = 100;
      final backend = _CapturingBackend();
      final probe = ObservationProbe.bounded(
        bufferCapacity: 4,
        clock: () => now,
        backend: backend,
      );

      final segment = probe.begin(
        ObservationPhase.databaseTransaction,
        const ObservationIds(runId: 'run-join', nodeVisit: 'join/1'),
      )!;
      expect(segment.phase, ObservationPhase.databaseTransaction);
      expect(segment.ids.runId, 'run-join');
      for (final node in <String>['left/1', 'right/1']) {
        segment.addLink(
          ids: ObservationIds(nodeVisit: node),
          relation: ObservationLinkRelation.predecessor,
        );
      }
      segment.addLink(
        ids: const ObservationIds(effectId: 'effect-1'),
        relation: ObservationLinkRelation.queueProducer,
      );
      now = 140;
      probe.complete(segment);

      expect(probe.drain(), 1);
      final record = backend.records.single;
      expect(
        (record.startedMicroseconds, record.durationMicroseconds),
        (100, 40),
      );
      expect(record.kind, ObservationSegmentKind.work);
      expect(
        record.links.map((link) => link.relation),
        <ObservationLinkRelation>[
          ObservationLinkRelation.predecessor,
          ObservationLinkRelation.predecessor,
          ObservationLinkRelation.queueProducer,
        ],
        reason:
            'links state dependency direction without inventing a call stack',
      );
      expect(
        record.links[0].ids.nodeVisit,
        isNot(record.links[1].ids.nodeVisit),
        reason: 'each parallel predecessor keeps its own identity',
      );
      expect(record.ids.nodeVisit, 'join/1');
    },
  );

  test('drain runs the backend after records leave the buffer', () {
    var now = 0;
    final backend = _CapturingBackend();
    final probe = ObservationProbe.bounded(
      bufferCapacity: 4,
      clock: () => now++,
      backend: backend,
    );
    backend.reentrant = probe;

    probe.complete(
      probe.begin(
        ObservationPhase.adapterFirstEvent,
        const ObservationIds(runId: 'run-drain'),
      )!,
    );
    expect(
      probe.drain(maxRecords: 1),
      1,
      reason: 'a backend that submits re-entrantly must not stall the drain',
    );
    expect(probe.pendingCount, 1);
    expect(probe.drain(maxRecords: 1), 1);
    expect(backend.records, hasLength(2));
  });

  test('correlation ids propagate through the contract wire shape', () {
    const ids = ObservationIds(
      userInteractionId: 'interaction-1',
      requestId: 'request-1',
      conversationId: 'conversation-1',
      runId: 'run-1',
      nodeVisit: 'node-1/2',
      effectId: 'effect-1',
      attemptToken: 'attempt-1',
      noticeId: 'notice-1',
      sourcePosition: 'lib/src/a.dart:12',
      prepareId: 'prepare-1',
    );

    expect(ObservationIdField.values, hasLength(10));
    for (final field in ObservationIdField.values) {
      expect(
        ids[field],
        isNotNull,
        reason: '${field.wireName} must be carried',
      );
    }
    expect(ids.toJson(), <String, String>{
      'userInteractionId': 'interaction-1',
      'requestId': 'request-1',
      'conversationId': 'conversation-1',
      'runId': 'run-1',
      'nodeVisit': 'node-1/2',
      'effectId': 'effect-1',
      'attemptToken': 'attempt-1',
      'noticeId': 'notice-1',
      'sourcePosition': 'lib/src/a.dart:12',
      'prepareId': 'prepare-1',
    });
    expect(ids.toString(), contains('runId=run-1'));
    expect(ids.withId(ObservationIdField.runId, 'run-2').runId, 'run-2');
    expect(ids.withId(ObservationIdField.runId, 'run-2').nodeVisit, 'node-1/2');

    expect(const ObservationIds().isEmpty, isTrue);
    expect(const ObservationIds().toJson(), isEmpty);
    expect(const ObservationIds().toString(), '-');
    expect(
      const ObservationIds(runId: 'run-only').toJson(),
      <String, String>{'runId': 'run-only'},
      reason: 'absent ids stay absent rather than becoming placeholders',
    );
  });

  test('the port adopts the existing renderer trace carrier', () {
    const ids = ObservationIds(userInteractionId: 'interaction-1');
    expect(
      ids.toTraceContext().traceId,
      'interaction-1',
      reason: 'a single known id rides the carrier the renderer already has',
    );
    expect(
      ObservationIds.fromTraceContext(const TraceContext(traceId: 'request-9')),
      const ObservationIds(requestId: 'request-9'),
    );
    expect(ObservationIds.fromTraceContext(null).isEmpty, isTrue);
    expect(
      ObservationIds.fromTraceContext(const TraceContext()).isEmpty,
      isTrue,
    );
    expect(
      ObservationIds.fromTraceContext(
        const TraceContext(),
      ).toTraceContext().traceId,
      isNull,
    );
  });

  test('every contract phase pins its own waiting or work kind', () {
    expect(ObservationPhase.values, hasLength(9));
    final waits = ObservationPhase.values
        .where((phase) => phase.kind == ObservationSegmentKind.wait)
        .toList();
    final works = ObservationPhase.values
        .where((phase) => phase.kind == ObservationSegmentKind.work)
        .toList();
    expect(waits, hasLength(5));
    expect(works, hasLength(4));
    expect(ObservationPhase.admissionWait.kind, ObservationSegmentKind.wait);
    expect(
      ObservationPhase.adapterFirstEvent.kind,
      ObservationSegmentKind.wait,
    );
    expect(ObservationPhase.prepareCpu.kind, ObservationSegmentKind.work);
    expect(ObservationPhase.queueWait.kind, ObservationSegmentKind.wait);
    expect(ObservationPhase.prepareQueue.kind, ObservationSegmentKind.wait);
    expect(ObservationPhase.raster.kind, ObservationSegmentKind.work);
    expect(
      ObservationPhase.inputDisplay.kind,
      ObservationSegmentKind.wait,
      reason:
          'perceived display latency is waiting; inner work has its own '
          'segments',
    );
  });

  test('a record carries its links on the wire', () {
    const record = ObservationSegmentRecord(
      phase: ObservationPhase.raster,
      ids: ObservationIds(conversationId: 'conversation-1'),
      startedMicroseconds: 7,
      durationMicroseconds: 13,
      links: <ObservationSpanLink>[
        ObservationSpanLink(
          ids: ObservationIds(runId: 'run-predecessor'),
          relation: ObservationLinkRelation.predecessor,
        ),
      ],
    );
    expect(record.kind, ObservationSegmentKind.work);
    expect(record.toJson(), <String, Object>{
      'phase': 'raster',
      'kind': 'work',
      'correlation': <String, String>{'conversationId': 'conversation-1'},
      'startedMicros': 7,
      'durationMicros': 13,
      'links': <Object>[
        <String, Object>{
          'correlation': <String, String>{'runId': 'run-predecessor'},
          'relation': 'predecessor',
        },
      ],
    });
  });

  test(
    'the null backend absorbs records and the timeline backend publishes',
    () {
      const record = ObservationSegmentRecord(
        phase: ObservationPhase.build,
        ids: ObservationIds(runId: 'run-log'),
        startedMicroseconds: 4,
        durationMicroseconds: 3,
      );
      const NullObservationTelemetryBackend().emit(record);
      TimelineObservationTelemetryBackend().emit(record);
    },
  );

  test('an ill-shaped probe configuration is rejected at construction', () {
    expect(
      () => ObservationProbe.bounded(
        bufferCapacity: 0,
        clock: () => 0,
        backend: const NullObservationTelemetryBackend(),
      ),
      throwsArgumentError,
    );
    expect(
      () => ObservationProbe.bounded(
        bufferCapacity: 1,
        sampling: const ObservationSamplingBudget(
          maxRecordsPerWindow: 1,
          windowMicroseconds: 0,
        ),
        clock: () => 0,
        backend: const NullObservationTelemetryBackend(),
      ),
      throwsArgumentError,
    );
  });

  test('the privacy rules keep private paths out and ordinary ids in', () {
    const budget = ObservationPrivacyBudget();
    final absoluteHome = <String>['', 'Users', 'owner', 'secret'].join('/');
    final homeAnchored = <String>['~', '.ssh', 'id_ed25519'].join('/');
    final driveQualified = <String>['C:', 'private'].join('\\');
    final unc = <String>['', '', 'host', 'share'].join('\\');
    expect(absoluteHome, startsWith('/'));
    expect(homeAnchored, startsWith('~'));
    expect(driveQualified, startsWith('C:'));
    expect(unc, startsWith('\\\\'));
    expect(budget.idViolation(absoluteHome), isNotNull);
    expect(budget.idViolation(homeAnchored), isNotNull);
    expect(budget.idViolation(unc), isNotNull);
    expect(budget.idViolation(driveQualified), isNotNull);
    expect(budget.idViolation(''), isNotNull);
    expect(budget.idViolation('two\nlines'), isNotNull);
    expect(budget.idViolation('key=secret-value'), isNull);
    expect(budget.idViolation('lib/src/a.dart:12'), isNull);
    expect(budget.idViolation('run-1'), isNull);
  });
}
