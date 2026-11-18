import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/composition/built_in_layout_composition.dart';
import 'package:licoup/src/composition/client_app_composition.dart';
import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/stream_observation.dart';
import 'package:licoup/src/platform/native_client/stream_observation_journal.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';
import 'package:path/path.dart' as p;

import 'transport_fixture.dart';

/// The production client composition is the owner of transport observation.
///
/// The port and its admission semantics are already proven by
/// `stream_observation_test.dart`; this suite proves the other half: the real
/// application startup path installs a real backend, records what the native
/// stdio transport admitted, keeps those records inside the client's own data
/// root under every bound, and carries no observation state at all when the
/// composition does not opt in.
///
/// Every case builds its own disposable data root. No case reads or writes the
/// developer's real client state.
void main() {
  test(
    'the production composition retains admitted transport phases under its own data root',
    () async {
      final root = await _oneOffRoot();
      final portableData = PortableDataRoot(dataDirectoryOverride: root);
      final context = SyntheticProcessContext(
        (request) => request.reply(const {'ok': true}),
      );
      final controller = ClientAppComposition.createProductionController(
        layout: BuiltInLayoutComposition(),
        portableData: portableData,
        processContext: context,
      );
      addTearDown(controller.close);

      final port = controller.agentService.streamObservation;
      expect(
        port,
        isNotNull,
        reason: 'the production composition installs an observation port',
      );
      expect(port!.isInstalled, isTrue);

      // The ordered command lane and the read pool each own sessions; both must
      // report through the port the production composition installed.
      expect(await controller.agentService.runCli(const ['version']), {
        'ok': true,
      });
      expect(await controller.agentService.runCli(const ['skill', 'list']), {
        'ok': true,
      });
      expect(
        context.startCount,
        greaterThanOrEqualTo(2),
        reason: 'the read pool opens its own native session',
      );

      final sentIds = context.processes
          .expand((process) => process.received)
          .map((frame) => frame['id'])
          .whereType<String>()
          .toSet();
      expect(sentIds, isNotEmpty);

      // The accepted writes are drained exactly as a data-home relocation
      // drains them before it starts copying.
      await portableData.stopAppManagedWritersAndDrain();

      final file = _journalFile(root);
      expect(
        file.path,
        startsWith(root.path),
        reason: 'records stay inside the composition root',
      );
      final records = await _journalRecords(file);
      expect(records, isNotEmpty);
      expect(
        records.map((record) => record['phase']).toSet(),
        containsAll(StreamObservationPhase.values.map((phase) => phase.name)),
      );
      expect(
        records
            .where((record) => record['phase'] == 'install')
            .map((record) => record['correlationId'])
            .toSet(),
        containsAll(sentIds),
        reason: 'an installed expectation carries the real wire request id',
      );
      expect(
        records.map((record) => record['lane']).toSet(),
        {'ordered'},
        reason: 'this composition issues no control attempt',
      );
      expect(port.retainedCount, greaterThanOrEqualTo(records.length));
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'oversized and identifying submissions are refused and never reach the journal',
    () async {
      final root = await _oneOffRoot();
      final portableData = PortableDataRoot(dataDirectoryOverride: root);
      final controller = ClientAppComposition.createProductionController(
        layout: BuiltInLayoutComposition(),
        portableData: portableData,
        processContext: SyntheticProcessContext(
          (request) => request.reply(const {'ok': true}),
        ),
      );
      addTearDown(controller.close);

      expect(await controller.agentService.runCli(const ['version']), {
        'ok': true,
      });

      final port = controller.agentService.streamObservation!;
      final overLongCorrelation = 'x' * (port.maxCorrelationChars + 1);
      expect(
        _refusal(
          port.observe(
            phase: StreamObservationPhase.dispatch,
            privacy: StreamObservationPrivacy.identifying,
            sizeBytes: 8,
          ),
        ),
        StreamObservationRefusal.identifyingRecord,
      );
      expect(
        _refusal(
          port.observe(
            phase: StreamObservationPhase.dispatch,
            sizeBytes: port.maxRecordBytes + 1,
          ),
        ),
        StreamObservationRefusal.oversizedRecord,
      );
      expect(
        _refusal(
          port.observe(
            phase: StreamObservationPhase.dispatch,
            sizeBytes: 8,
            correlationId: overLongCorrelation,
          ),
        ),
        StreamObservationRefusal.oversizedCorrelation,
      );

      await portableData.stopAppManagedWritersAndDrain();

      final file = _journalFile(root);
      final raw = await file.readAsString();
      final records = await _journalRecords(file);
      expect(records, isNotEmpty);
      expect(
        raw,
        isNot(contains(overLongCorrelation)),
        reason: 'a refused correlation identity leaves no trace',
      );
      expect(
        raw,
        isNot(contains(root.path)),
        reason: 'no record carries a path',
      );
      for (final record in records) {
        expect(record.keys.toSet(), _recordKeys);
        expect(record['privacy'], 'aggregate');
        expect(
          (record['correlationId']! as String).length,
          lessThanOrEqualTo(port.maxCorrelationChars),
        );
        expect(
          record['sizeBytes']! as int,
          lessThanOrEqualTo(port.maxRecordBytes),
        );
      }
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test(
    'the journal keeps the newest records inside its byte bound',
    () async {
      final root = await _oneOffRoot();
      final portableData = PortableDataRoot(dataDirectoryOverride: root);
      final journal = StreamObservationJournal(
        portableData: portableData,
        maxBytes: 2048,
        clock: () => DateTime.utc(2026, 1, 1),
      );
      final port = StreamObservationPort()..installBackend(journal);

      for (var index = 0; index < 300; index += 1) {
        expect(
          port.observe(
            phase: StreamObservationPhase.dispatch,
            sizeBytes: index,
            correlationId: 'request-$index',
          ),
          isA<StreamObservationAdmitted>(),
        );
      }

      await portableData.stopAppManagedWritersAndDrain();

      final file = _journalFile(root);
      expect(await file.length(), lessThanOrEqualTo(2048));
      final records = await _journalRecords(file);
      expect(records.length, greaterThan(1));
      expect(
        records.map((record) => record['sequence']),
        orderedEquals(
          List<int>.generate(
            records.length,
            (index) => index + 301 - records.length,
          ),
        ),
        reason: 'only whole, newest lines survive rotation',
      );
      expect(records.last['correlationId'], 'request-299');
      expect(
        records.map((record) => record['correlationId']),
        isNot(contains('request-0')),
      );
      expect(journal.writtenCount, 300);
      expect(journal.droppedCount, 0);
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('a waiting queue beyond its bound drops the oldest record', () async {
    final root = await _oneOffRoot();
    final portableData = PortableDataRoot(dataDirectoryOverride: root);
    final journal = StreamObservationJournal(
      portableData: portableData,
      maxPendingRecords: 4,
    );

    for (var index = 0; index < 10; index += 1) {
      journal.acceptStreamObservation(_record(index));
    }

    // At most the bound waits, and at most one record is in flight while the
    // bound is applied, so the rest must already have been dropped.
    expect(journal.pendingCount, lessThanOrEqualTo(4));
    expect(journal.droppedCount, greaterThanOrEqualTo(5));

    await portableData.stopAppManagedWritersAndDrain();
    // The root refuses the records still waiting on the next event-loop turn,
    // exactly as it refuses an observation submitted after the drain.
    await Future<void>.delayed(Duration.zero);

    expect(journal.pendingCount, 0);
    expect(
      journal.writtenCount + journal.droppedCount,
      10,
      reason: 'every accepted record is written or refused, never retained',
    );
    final records = await _journalRecords(_journalFile(root));
    expect(records, isNotEmpty);
    expect(records.length, lessThanOrEqualTo(4));
    for (final record in records) {
      final index = int.parse(
        (record['correlationId']! as String).split('-').last,
      );
      expect(index, inInclusiveRange(0, 9));
    }
  });

  test(
    'a quiesced data root refuses observations instead of retaining them',
    () async {
      final root = await _oneOffRoot();
      final portableData = PortableDataRoot(dataDirectoryOverride: root);
      final journal = StreamObservationJournal(portableData: portableData);

      await portableData.stopAppManagedWritersAndDrain();
      journal.acceptStreamObservation(_record(0));
      await Future<void>.delayed(Duration.zero);

      expect(journal.writtenCount, 0);
      expect(journal.pendingCount, 0);
      expect(journal.droppedCount, 1);
      expect(await _journalFile(root).exists(), isFalse);
    },
  );

  test(
    'a composition without the opt-in carries no observation state',
    () async {
      final root = await _oneOffRoot();
      final portableData = PortableDataRoot(dataDirectoryOverride: root);
      final context = SyntheticProcessContext(
        (request) => request.reply(const {'ok': true}),
      );
      final controller = ClientController(
        portableData: portableData,
        processContext: context,
      );
      addTearDown(controller.close);

      expect(controller.agentService.streamObservation, isNull);
      expect(await controller.agentService.runCli(const ['version']), {
        'ok': true,
      });
      await portableData.stopAppManagedWritersAndDrain();

      expect(
        await Directory(
          p.join(
            root.path,
            'client-state',
            StreamObservationJournal.directoryName,
          ),
        ).exists(),
        isFalse,
        reason: 'an unobserved transport writes nothing',
      );
    },
  );
}

/// Keys one retained line may carry. The set is closed on purpose: message
/// text, payloads and paths have no field to travel in.
final Set<String> _recordKeys = <String>{
  'schema',
  'sequence',
  'observedAt',
  'phase',
  'lane',
  'privacy',
  'correlationId',
  'sizeBytes',
  'backlogBytes',
};

/// The journal file the production layout requires, spelled independently of
/// `PortableDataRoot.clientDirectory()` so the location itself is asserted.
File _journalFile(Directory dataRoot) => File(
  p.join(
    dataRoot.path,
    'client-state',
    StreamObservationJournal.directoryName,
    StreamObservationJournal.fileName,
  ),
);

Future<List<Map<String, dynamic>>> _journalRecords(File file) async {
  if (!await file.exists()) return const [];
  return <Map<String, dynamic>>[
    for (final line in const LineSplitter().convert(await file.readAsString()))
      if (line.trim().isNotEmpty) jsonDecode(line) as Map<String, dynamic>,
  ];
}

StreamObservationRefusal _refusal(StreamObservationAdmission admission) {
  expect(admission, isA<StreamObservationRefused>());
  return (admission as StreamObservationRefused).reason;
}

StreamObservationRecord _record(int index) => StreamObservationRecord(
  phase: StreamObservationPhase.dispatch,
  lane: StreamObservationLane.ordered,
  privacy: StreamObservationPrivacy.aggregate,
  correlationId: 'request-$index',
  sizeBytes: index,
  backlogBytes: 0,
);

Future<Directory> _oneOffRoot() async {
  final root = await Directory.systemTemp.createTemp(
    'stream-observation-production-',
  );
  addTearDown(() async {
    if (root.existsSync()) await root.delete(recursive: true);
  });
  return root;
}
