import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'package:licoup/src/platform/native_client/agent_service_stdio_rpc/stream_observation.dart';
import 'package:licoup/src/platform/storage/bounded_json_lines.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';

/// The production [StreamObservationBackend]: retains admitted transport phase
/// records as one bounded JSON-lines file inside the client's own data root.
///
/// The port owns admission and this backend owns retention. Only records the
/// port already admitted reach [acceptStreamObservation], so an identifying,
/// over-long or oversized submission never becomes a line here; a refusal is
/// returned to the submitter and leaves no trace.
///
/// Every bound exists because the observed stream does not:
///
/// * the line is written under `<client-state>/observability/`, resolved from
///   the same [PortableDataRoot] instance the client drains before a data-home
///   relocation, so the file never leaves the client's own root;
/// * at most [maxPendingRecords] records wait for the disk; an arrival beyond
///   that drops the oldest waiting record instead of growing with the stream;
/// * the file never exceeds [maxBytes]: the newest complete lines are retained
///   when the next record would pass the bound, so the phase facts nearest a
///   failure survive a long session;
/// * a storage failure refuses the waiting records instead of retrying without
///   bound, and never propagates into the transport this backend observes.
final class StreamObservationJournal implements StreamObservationBackend {
  StreamObservationJournal({
    required PortableDataRoot portableData,
    this.maxBytes = defaultMaxBytes,
    this.maxPendingRecords = defaultMaxPendingRecords,
    DateTime Function()? clock,
  }) : _portableData = portableData,
       _clock = clock ?? DateTime.now {
    if (maxBytes <= 0) {
      throw ArgumentError.value(maxBytes, 'maxBytes', 'must be positive');
    }
    if (maxPendingRecords <= 0) {
      throw ArgumentError.value(
        maxPendingRecords,
        'maxPendingRecords',
        'must be positive',
      );
    }
  }

  /// Directory this journal owns under the client state root.
  static const String directoryName = 'observability';

  /// File this journal owns inside [directoryName].
  static const String fileName = 'stream-observation.jsonl';

  /// Schema marker of every retained line.
  static const String schema = 'licoup.stream-observation.v1';

  /// Default byte bound of the journal file.
  static const int defaultMaxBytes = 512 * 1024;

  /// Default number of records that may wait for the disk.
  static const int defaultMaxPendingRecords = 512;

  /// Byte bound the journal file never exceeds.
  final int maxBytes;

  /// Records that may wait for the disk before the oldest waiting one drops.
  final int maxPendingRecords;

  final PortableDataRoot _portableData;
  final DateTime Function() _clock;
  final ListQueue<String> _pending = ListQueue<String>();
  var _flushing = false;
  var _sequence = 0;
  var _writtenCount = 0;
  var _droppedCount = 0;

  /// Records written to the journal file so far.
  int get writtenCount => _writtenCount;

  /// Admitted records dropped before they reached the file.
  int get droppedCount => _droppedCount;

  /// Records currently waiting for the disk.
  int get pendingCount => _pending.length;

  /// The directory this journal writes under [portableData].
  static Future<Directory> directoryFor(PortableDataRoot portableData) async {
    final clientDirectory = await portableData.clientDirectory();
    return Directory(p.join(clientDirectory.path, directoryName));
  }

  /// Bounds the waiting queue, then admits the record into app-managed write
  /// tracking before any asynchronous work starts, so a relocation drain that
  /// already began still covers this record.
  @override
  void acceptStreamObservation(StreamObservationRecord record) {
    if (_pending.length >= maxPendingRecords) {
      _pending.removeFirst();
      _droppedCount += 1;
    }
    _pending.addLast(_encode(record));
    _flush();
  }

  String _encode(StreamObservationRecord record) {
    _sequence += 1;
    return '${jsonEncode(<String, Object>{'schema': schema, 'sequence': _sequence, 'observedAt': _clock().toUtc().toIso8601String(), 'phase': record.phase.name, 'lane': record.lane.name, 'privacy': record.privacy.name, 'correlationId': record.correlationId, 'sizeBytes': record.sizeBytes, 'backlogBytes': record.backlogBytes})}\n';
  }

  void _flush() {
    if (_flushing || _pending.isEmpty) return;
    _flushing = true;
    unawaited(
      _portableData
          .withAppManagedWriter(_writePending)
          .catchError((Object _) {
            // The root refuses further app-managed writes: it is quiescing for a
            // relocation, or the write failed. Records still waiting are refused
            // with it instead of being retained outside the root's admission.
            _droppedCount += _pending.length;
            _pending.clear();
          })
          .whenComplete(() {
            _flushing = false;
            // Records that arrived while this batch ran are written by the next
            // admitted batch rather than by an unbounded background loop.
            _flush();
          }),
    );
  }

  Future<void> _writePending() async {
    try {
      var appended = 0;
      while (_pending.isNotEmpty && appended < maxPendingRecords) {
        await _append(_pending.removeFirst());
        appended += 1;
        _writtenCount += 1;
      }
    } on Object {
      // Observation is never allowed to fail the transport, and retrying a
      // failing root forever would grow with the stream. The records still
      // waiting are refused instead.
      _droppedCount += _pending.length;
      _pending.clear();
    }
  }

  Future<void> _append(String line) async {
    final directory = await directoryFor(_portableData);
    await _ensurePlainDirectory(directory);
    final file = File(p.join(directory.path, fileName));
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    if (type == FileSystemEntityType.link ||
        (type != FileSystemEntityType.notFound &&
            type != FileSystemEntityType.file)) {
      throw const FileSystemException(
        'Stream observation path is not a regular file.',
      );
    }

    final encoded = utf8.encode(line);
    final handle = await file.open(mode: FileMode.append);
    try {
      await handle.lock(FileLock.exclusive);
      final length = await handle.length();
      if (length + encoded.length <= maxBytes) {
        await handle.writeFrom(encoded);
        await handle.flush();
        return;
      }
      await handle.flush();
    } finally {
      try {
        await handle.unlock();
      } on FileSystemException {
        // The handle may not have acquired the lock if opening failed late.
      }
      await handle.close();
    }

    await file.writeAsBytes(
      retainJsonLinesTail(await file.readAsBytes(), encoded, maxBytes),
      flush: true,
    );
  }

  Future<void> _ensurePlainDirectory(Directory directory) async {
    final type = await FileSystemEntity.type(
      directory.path,
      followLinks: false,
    );
    if (type == FileSystemEntityType.link ||
        (type != FileSystemEntityType.notFound &&
            type != FileSystemEntityType.directory)) {
      throw const FileSystemException(
        'Stream observation directory is not a regular directory.',
      );
    }
    if (type == FileSystemEntityType.notFound) {
      await directory.create(recursive: true);
    }
  }
}
