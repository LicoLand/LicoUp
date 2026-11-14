import 'dart:collection';

import 'package:licoup/src/platform/native_client/native_rpc_priority.dart';

/// Handle to a pending entry in [RpcOperationPendingQueue], enabling O(1)
/// cancellation and dynamic reprioritization.
abstract interface class RpcPendingEntryHandle<T> {
  /// Whether this entry is still pending in the queue.
  bool get isPending;

  /// Whether this entry was cancelled before execution.
  bool get isCancelled;

  /// Whether this entry is currently classified as background work.
  bool get isBackground;

  /// The priority token bound to this entry, if any.
  RpcPriorityToken? get priority;

  /// Estimated payload byte size associated with this entry.
  int get byteSize;

  /// Arrival sequence of this entry for FIFO stability.
  int get sequence;

  /// Cancels this pending entry in O(1) time. Returns true if cancelled.
  bool cancel();

  /// Dynamically reprioritizes this entry in O(1) time between foreground
  /// and background FIFOs.
  void reprioritize({required bool background});
}

/// Plain FIFO queue backed by standard [ListQueue] when dynamic cancellation
/// or reprioritization is not required.
final class RpcFifoQueue<T> {
  RpcFifoQueue({this.maxPendingBytes, this.maxPendingCount});

  final int? maxPendingBytes;
  final int? maxPendingCount;
  final ListQueue<({T item, int byteSize})> _queue = ListQueue();
  var _totalPayloadBytes = 0;

  bool get isEmpty => _queue.isEmpty;
  bool get isNotEmpty => _queue.isNotEmpty;
  int get length => _queue.length;
  int get totalPayloadBytes => _totalPayloadBytes;

  bool get hasBackpressure =>
      (maxPendingBytes != null && _totalPayloadBytes >= maxPendingBytes!) ||
      (maxPendingCount != null && _queue.length >= maxPendingCount!);

  void add(T item, {int byteSize = 0}) {
    assert(byteSize >= 0, 'byteSize must be non-negative');
    _queue.addLast((item: item, byteSize: byteSize));
    _totalPayloadBytes += byteSize;
  }

  T takeNext() {
    if (_queue.isEmpty) {
      throw StateError('No elements in RpcFifoQueue');
    }
    final entry = _queue.removeFirst();
    _totalPayloadBytes -= entry.byteSize;
    return entry.item;
  }

  void clear() {
    _queue.clear();
    _totalPayloadBytes = 0;
  }
}

/// Shared pending queue for ordered commands and parallel reads. Uses standard
/// [LinkedList] entries for O(1) enqueue, cancel, and reprioritize operations.
///
/// Dispatches via front (foreground) and back (background) FIFOs with bounded
/// batching: foreground work has priority, but continuous foreground arrivals
/// yield to background work after a bounded batch limit (default 8) to prevent
/// background starvation.
final class RpcOperationPendingQueue<T> {
  RpcOperationPendingQueue({
    this.foregroundBatchLimit = defaultForegroundBatchLimit,
    this.maxPendingBytes,
    this.maxPendingCount,
  }) : assert(
         foregroundBatchLimit > 0,
         'foregroundBatchLimit must be positive',
       );

  static const int defaultForegroundBatchLimit = 8;
  static const int maxFrameBytesBound = 16 * 1024 * 1024; // 16 MiB

  final int foregroundBatchLimit;
  final int? maxPendingBytes;
  final int? maxPendingCount;

  final LinkedList<_PendingEntry<T>> _foreground =
      LinkedList<_PendingEntry<T>>();
  final LinkedList<_PendingEntry<T>> _background =
      LinkedList<_PendingEntry<T>>();

  var _foregroundCount = 0;
  var _backgroundCount = 0;
  var _totalPayloadBytes = 0;
  var _consecutiveForegroundBatch = 0;
  var _entrySequence = 0;

  bool get isEmpty => _foregroundCount == 0 && _backgroundCount == 0;
  bool get isNotEmpty => !isEmpty;
  int get length => _foregroundCount + _backgroundCount;
  int get foregroundCount => _foregroundCount;
  int get backgroundCount => _backgroundCount;
  int get totalPayloadBytes => _totalPayloadBytes;

  bool get hasBackpressure =>
      (maxPendingBytes != null && _totalPayloadBytes >= maxPendingBytes!) ||
      (maxPendingCount != null && length >= maxPendingCount!);

  /// Adds [run] to the pending queue. Returns an [RpcPendingEntryHandle] for
  /// O(1) cancellation or dynamic reprioritization.
  RpcPendingEntryHandle<T> add(
    T run, {
    RpcPriorityToken? priority,
    int byteSize = 0,
    void Function()? onCancelled,
  }) {
    assert(byteSize >= 0, 'byteSize must be non-negative');
    final isBackground = priority?.background ?? false;
    final entry = _PendingEntry<T>(
      queue: this,
      run: run,
      priority: priority,
      byteSize: byteSize,
      isBackground: isBackground,
      sequence: ++_entrySequence,
      onCancelled: onCancelled,
    );

    if (isBackground) {
      _background.add(entry);
      _backgroundCount += 1;
    } else {
      _foreground.add(entry);
      _foregroundCount += 1;
    }

    _totalPayloadBytes += byteSize;

    if (priority != null) {
      priority.addListener(entry._tokenListener);
    }

    return entry;
  }

  /// Removes and returns the next runnable entry whose lane [eligible] accepts,
  /// together with the lane it was taken from. Uses the same foreground
  /// preference and bounded batch rotation as [takeNext]; returns null when only
  /// ineligible work remains, so a caller can refuse to occupy capacity that a
  /// lane it must not starve still needs.
  ({T run, bool isBackground})? takeNextEligible(
    bool Function(bool isBackground) eligible,
  ) {
    if (isEmpty) {
      return null;
    }
    final foregroundEligible = eligible(false);
    final backgroundEligible = eligible(true);
    if (!foregroundEligible && !backgroundEligible) {
      return null;
    }

    _PendingEntry<T> entry;
    if (_foreground.isNotEmpty && _background.isNotEmpty) {
      final preferForeground =
          _consecutiveForegroundBatch < foregroundBatchLimit;
      final takeForeground =
          (preferForeground && foregroundEligible) || !backgroundEligible;
      if (takeForeground) {
        if (preferForeground) {
          _consecutiveForegroundBatch += 1;
        }
        entry = _foreground.first;
        entry.unlink();
        _foregroundCount -= 1;
      } else {
        // Bounded batch rotation: yield to background FIFO.
        _consecutiveForegroundBatch = 0;
        entry = _background.first;
        entry.unlink();
        _backgroundCount -= 1;
      }
    } else if (_foreground.isNotEmpty) {
      if (!foregroundEligible) {
        return null;
      }
      _consecutiveForegroundBatch = 0;
      entry = _foreground.first;
      entry.unlink();
      _foregroundCount -= 1;
    } else {
      if (!backgroundEligible) {
        return null;
      }
      _consecutiveForegroundBatch = 0;
      entry = _background.first;
      entry.unlink();
      _backgroundCount -= 1;
    }

    entry._isPending = false;
    _totalPayloadBytes -= entry.byteSize;
    entry.priority?.removeListener(entry._tokenListener);
    return (run: entry.run, isBackground: entry.isBackground);
  }

  /// Removes and returns the next runnable item according to foreground priority
  /// and bounded batch rotation.
  T takeNext() => takeNextEligible((_) => true)!.run;

  void clear() {
    while (_foreground.isNotEmpty) {
      final entry = _foreground.first;
      entry.unlink();
      entry._isPending = false;
      entry.priority?.removeListener(entry._tokenListener);
    }
    while (_background.isNotEmpty) {
      final entry = _background.first;
      entry.unlink();
      entry._isPending = false;
      entry.priority?.removeListener(entry._tokenListener);
    }
    _foregroundCount = 0;
    _backgroundCount = 0;
    _totalPayloadBytes = 0;
    _consecutiveForegroundBatch = 0;
  }

  void _onEntryCancelled(_PendingEntry<T> entry) {
    if (entry.isBackground) {
      _backgroundCount -= 1;
    } else {
      _foregroundCount -= 1;
    }
    _totalPayloadBytes -= entry.byteSize;
    entry.priority?.removeListener(entry._tokenListener);
    entry.onCancelled?.call();
  }

  void _reinsertEntry(_PendingEntry<T> entry) {
    if (entry.isBackground) {
      _foregroundCount -= 1;
      if (_background.isEmpty || entry.sequence > _background.last.sequence) {
        _background.add(entry);
      } else if (entry.sequence < _background.first.sequence) {
        _background.first.insertBefore(entry);
      } else {
        var cur = _background.last;
        while (cur.sequence > entry.sequence && cur.previous != null) {
          cur = cur.previous!;
        }
        if (cur.sequence > entry.sequence) {
          cur.insertBefore(entry);
        } else {
          cur.insertAfter(entry);
        }
      }
      _backgroundCount += 1;
    } else {
      _backgroundCount -= 1;
      if (_foreground.isEmpty || entry.sequence > _foreground.last.sequence) {
        _foreground.add(entry);
      } else if (entry.sequence < _foreground.first.sequence) {
        _foreground.first.insertBefore(entry);
      } else {
        var cur = _foreground.last;
        while (cur.sequence > entry.sequence && cur.previous != null) {
          cur = cur.previous!;
        }
        if (cur.sequence > entry.sequence) {
          cur.insertBefore(entry);
        } else {
          cur.insertAfter(entry);
        }
      }
      _foregroundCount += 1;
    }
  }
}

final class _PendingEntry<T> extends LinkedListEntry<_PendingEntry<T>>
    implements RpcPendingEntryHandle<T> {
  _PendingEntry({
    required this.queue,
    required this.run,
    this.priority,
    this.byteSize = 0,
    required this.isBackground,
    required this.sequence,
    this.onCancelled,
  });

  final RpcOperationPendingQueue<T> queue;
  final T run;
  @override
  final RpcPriorityToken? priority;
  @override
  final int byteSize;
  @override
  final int sequence;
  final void Function()? onCancelled;

  @override
  bool isBackground;
  var _isPending = true;
  var _isCancelled = false;

  @override
  bool get isPending => _isPending;

  @override
  bool get isCancelled => _isCancelled;

  late final void Function(bool background) _tokenListener = _onTokenChanged;

  void _onTokenChanged(bool background) {
    reprioritize(background: background);
  }

  @override
  bool cancel() {
    if (!_isPending || _isCancelled) return false;
    _isPending = false;
    _isCancelled = true;
    if (list != null) {
      unlink();
    }
    queue._onEntryCancelled(this);
    return true;
  }

  @override
  void reprioritize({required bool background}) {
    if (!_isPending || _isCancelled) return;
    if (isBackground == background) return;
    isBackground = background;
    if (list != null) {
      unlink();
    }
    queue._reinsertEntry(this);
  }
}
