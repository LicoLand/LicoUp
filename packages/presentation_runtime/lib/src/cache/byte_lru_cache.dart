import 'dart:collection';

import 'package:presentation_contract/presentation_contract.dart';

/// The outcome of inserting a value into a byte-bounded cache.
enum ByteCachePutStatus { stored, replaced, rejected }

/// A small immutable description of a cache entry.
final class ByteCacheEntry<Value> {
  const ByteCacheEntry({
    required this.key,
    required this.value,
    required this.bytes,
    required this.references,
  });

  final Object? key;
  final Value value;
  final int bytes;
  final int references;

  bool get isReferenced => references > 0;
}

/// A result returned by [ByteLruCache.put].
final class ByteCachePutResult {
  const ByteCachePutResult({
    required this.status,
    required this.evictedEntries,
  });

  final ByteCachePutStatus status;
  final int evictedEntries;

  bool get stored => status != ByteCachePutStatus.rejected;
}

/// A retained reference to a cache value.
///
/// Retained entries participate in the resident-byte count and cannot be
/// evicted until every lease is released. This keeps eviction from claiming
/// that a visible preparation block has already been freed.
final class ByteCacheLease<Value> {
  ByteCacheLease._({
    required this.value,
    required this.bytes,
    required void Function() release,
  }) : _release = release;

  final void Function() _release;
  final Value value;
  final int bytes;
  bool _released = false;

  bool get released => _released;

  void release() {
    if (_released) return;
    _released = true;
    _release();
  }
}

/// A version-aware key for prepared presentation values.
///
/// Request generations are deliberately not part of this key. A generation
/// protects installation of an asynchronous result, while the source
/// resource, field group, epoch, version, and optional variant determine the
/// prepared value itself.
final class VersionedCacheKey {
  const VersionedCacheKey({
    required this.resource,
    required this.fieldName,
    required this.source,
    this.variant,
  });

  static VersionedCacheKey fromRequest<T>(
    PreparationRequest<T> request, {
    Object? variant,
  }) {
    return VersionedCacheKey(
      resource: request.resourceKey,
      fieldName: request.resource.name,
      source: request.source,
      variant: variant,
    );
  }

  final ResourceKey resource;
  final String fieldName;
  final SourcePosition source;
  final Object? variant;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VersionedCacheKey &&
          other.resource == resource &&
          other.fieldName == fieldName &&
          other.source == source &&
          other.variant == variant;

  @override
  int get hashCode => Object.hash(resource, fieldName, source, variant);

  @override
  String toString() =>
      '$resource#$fieldName@$source${variant == null ? '' : ':$variant'}';
}

typedef PreparationCacheKey = VersionedCacheKey;
typedef VersionedResourceKey = VersionedCacheKey;

/// A byte-bounded least-recently-used cache.
///
/// [residentBytes] includes referenced entries. A referenced entry may be
/// moved to the end by [get], but it is never removed by ordinary eviction.
final class ByteLruCache<Key, Value> {
  ByteLruCache({required this.capacityBytes})
    : assert(capacityBytes >= 0, 'capacityBytes must not be negative') {
    if (capacityBytes < 0) {
      throw ArgumentError.value(
        capacityBytes,
        'capacityBytes',
        'must not be negative',
      );
    }
  }

  final int capacityBytes;
  final LinkedHashMap<Key, _ByteCacheEntry<Value>> _entries =
      LinkedHashMap<Key, _ByteCacheEntry<Value>>();
  int _residentBytes = 0;
  int _evictions = 0;
  int _rejectedPuts = 0;

  int get length => _entries.length;

  int get residentBytes => _residentBytes;

  int get referencedBytes => _entries.values
      .where((entry) => entry.references > 0)
      .fold<int>(0, (sum, entry) => sum + entry.bytes);

  int get availableBytes => capacityBytes - _residentBytes;

  int get evictions => _evictions;

  int get rejectedPuts => _rejectedPuts;

  bool containsKey(Key key) => _entries.containsKey(key);

  Value? get(Key key) {
    final entry = _touch(key);
    return entry?.value;
  }

  ByteCacheEntry<Value>? entry(Key key) {
    final value = _touch(key);
    if (value == null) return null;
    return ByteCacheEntry<Value>(
      key: key,
      value: value.value,
      bytes: value.bytes,
      references: value.references,
    );
  }

  /// Inserts or replaces a value, evicting only unreferenced LRU entries.
  ByteCachePutResult put(Key key, Value value, {required int bytes}) {
    if (bytes < 0) {
      throw ArgumentError.value(bytes, 'bytes', 'must not be negative');
    }
    if (bytes > capacityBytes) {
      _rejectedPuts++;
      return const ByteCachePutResult(
        status: ByteCachePutStatus.rejected,
        evictedEntries: 0,
      );
    }

    final existing = _entries[key];
    final existingBytes = existing?.bytes ?? 0;
    final requiredBytes = _residentBytes - existingBytes + bytes;
    final evicted = _evictFor(requiredBytes, except: key);
    if (evicted == null) {
      _rejectedPuts++;
      return const ByteCachePutResult(
        status: ByteCachePutStatus.rejected,
        evictedEntries: 0,
      );
    }
    if (_residentBytes - existingBytes + bytes > capacityBytes) {
      _rejectedPuts++;
      return ByteCachePutResult(
        status: ByteCachePutStatus.rejected,
        evictedEntries: evicted,
      );
    }

    if (existing != null) {
      _entries.remove(key);
      _residentBytes -= existing.bytes;
      existing.value = value;
      existing.bytes = bytes;
      _entries[key] = existing;
      _residentBytes += bytes;
      return ByteCachePutResult(
        status: ByteCachePutStatus.replaced,
        evictedEntries: evicted,
      );
    }

    _entries[key] = _ByteCacheEntry<Value>(value: value, bytes: bytes);
    _residentBytes += bytes;
    return ByteCachePutResult(
      status: ByteCachePutStatus.stored,
      evictedEntries: evicted,
    );
  }

  /// Retains a value until the returned lease is released.
  ByteCacheLease<Value>? retain(Key key) {
    final entry = _touch(key);
    if (entry == null) return null;
    entry.references++;
    return ByteCacheLease<Value>._(
      value: entry.value,
      bytes: entry.bytes,
      release: () => _release(key, entry),
    );
  }

  /// Removes an unreferenced entry. Referenced entries remain resident.
  bool remove(Key key) {
    final entry = _entries[key];
    if (entry == null || entry.references > 0) return false;
    _entries.remove(key);
    _residentBytes -= entry.bytes;
    return true;
  }

  /// Removes all unreferenced entries. Set [force] only when the owning
  /// runtime is being disposed and no visible consumer can retain a value.
  void clear({bool force = false}) {
    if (force) {
      _entries.clear();
      _residentBytes = 0;
      return;
    }
    for (final key in _entries.keys.toList()) {
      remove(key);
    }
  }

  _ByteCacheEntry<Value>? _touch(Key key) {
    final entry = _entries.remove(key);
    if (entry == null) return null;
    _entries[key] = entry;
    return entry;
  }

  int? _evictFor(int requiredBytes, {required Key except}) {
    final candidates = <Key>[];
    var projectedBytes = requiredBytes;
    while (projectedBytes > capacityBytes) {
      Key? candidate;
      for (final key in _entries.keys) {
        if (key == except || candidates.contains(key)) continue;
        final entry = _entries[key]!;
        if (entry.references == 0) {
          candidate = key;
          break;
        }
      }
      if (candidate == null) return null;
      candidates.add(candidate);
      final entry = _entries[candidate]!;
      projectedBytes -= entry.bytes;
    }
    for (final candidate in candidates) {
      final entry = _entries.remove(candidate)!;
      _residentBytes -= entry.bytes;
      _evictions++;
    }
    return candidates.length;
  }

  void _release(Object? key, _ByteCacheEntry<Value> entry) {
    final current = _entries[key as Key];
    if (!identical(current, entry) || entry.references == 0) return;
    entry.references--;
  }
}

final class _ByteCacheEntry<Value> {
  _ByteCacheEntry({required this.value, required this.bytes});

  Value value;
  int bytes;
  int references = 0;
}

/// A lightweight permit used by preparation queues to account for in-flight
/// payload bytes.
final class BytePermit {
  BytePermit._(this._owner, this.bytes);

  final ByteBackpressure _owner;
  final int bytes;
  bool _released = false;

  bool get released => _released;

  void release() {
    if (_released) return;
    _released = true;
    _owner._release(bytes);
  }
}

final class ByteBackpressureException implements Exception {
  const ByteBackpressureException({
    required this.requestedBytes,
    required this.capacityBytes,
    required this.inUseBytes,
  });

  final int requestedBytes;
  final int capacityBytes;
  final int inUseBytes;

  @override
  String toString() =>
      'ByteBackpressureException(requested: $requestedBytes, '
      'capacity: $capacityBytes, inUse: $inUseBytes)';
}

/// A non-growing byte budget for work currently crossing a preparation
/// boundary. Callers receive immediate backpressure instead of building an
/// unbounded waiter list.
final class ByteBackpressure {
  ByteBackpressure({required this.capacityBytes})
    : assert(capacityBytes >= 0, 'capacityBytes must not be negative') {
    if (capacityBytes < 0) {
      throw ArgumentError.value(
        capacityBytes,
        'capacityBytes',
        'must not be negative',
      );
    }
  }

  final int capacityBytes;
  int _inUseBytes = 0;

  int get inUseBytes => _inUseBytes;

  int get availableBytes => capacityBytes - _inUseBytes;

  bool tryAcquire(int bytes) {
    if (bytes < 0) {
      throw ArgumentError.value(bytes, 'bytes', 'must not be negative');
    }
    if (bytes > capacityBytes) return false;
    if (_inUseBytes + bytes > capacityBytes) return false;
    _inUseBytes += bytes;
    return true;
  }

  BytePermit acquire(int bytes) {
    _validate(bytes);
    if (!tryAcquire(bytes)) {
      throw ByteBackpressureException(
        requestedBytes: bytes,
        capacityBytes: capacityBytes,
        inUseBytes: _inUseBytes,
      );
    }
    return BytePermit._(this, bytes);
  }

  void _validate(int bytes) {
    if (bytes < 0 || bytes > capacityBytes) {
      throw ByteBackpressureException(
        requestedBytes: bytes,
        capacityBytes: capacityBytes,
        inUseBytes: _inUseBytes,
      );
    }
  }

  void _release(int bytes) {
    _inUseBytes -= bytes;
    assert(_inUseBytes >= 0, 'byte permits must be released once');
  }
}

typedef VersionedByteLruCache<Key, Value> = ByteLruCache<Key, Value>;
