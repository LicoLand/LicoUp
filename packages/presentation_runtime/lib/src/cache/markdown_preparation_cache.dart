import 'dart:collection';

import 'package:presentation_contract/presentation_contract.dart';

import '../preparation/markdown/message_markdown_models.dart';
import 'byte_lru_cache.dart';

/// Default byte budget for prepared Markdown, matching the plan's reference
/// default of 32 MiB.
const int defaultMarkdownPreparationCacheBytes = 32 * 1024 * 1024;

/// Upper bound on remembered cross-block reference versions.
const int _referenceVersionCapacity = 8192;

/// Upper bound on remembered block identities, used to tell a first-time block
/// apart from one whose prepared payload was evicted.
const int _knownBlockCapacity = 8192;

/// Stable identity of one block inside one resource.
final class MarkdownBlockIdentity {
  const MarkdownBlockIdentity(this.resource, this.blockId);

  final ResourceKey resource;
  final BlockId blockId;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MarkdownBlockIdentity &&
          other.resource == resource &&
          other.blockId == blockId;

  @override
  int get hashCode => Object.hash(resource, blockId);

  @override
  String toString() => '$resource#$blockId';
}

/// Key of one prepared block memo.
///
/// Offsets are deliberately absent: an edit anywhere earlier in the message
/// shifts every later block's range, while the block itself is unchanged and
/// its declared version already identifies its text. The memo records the text
/// length instead, so a same-version length change is still caught.
final class MarkdownBlockMemoKey {
  const MarkdownBlockMemoKey({
    required this.resource,
    required this.epoch,
    required this.blockId,
    required this.blockVersion,
    required this.textLength,
    required this.parserVersion,
    required this.syntaxConfig,
  });

  final ResourceKey resource;
  final SourceEpoch epoch;
  final BlockId blockId;
  final BlockVersion blockVersion;

  /// Length of the block text this memo was prepared from.
  final int textLength;
  final ParserVersion parserVersion;
  final SyntaxConfig syntaxConfig;

  MarkdownBlockIdentity get identity =>
      MarkdownBlockIdentity(resource, blockId);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is MarkdownBlockMemoKey &&
          other.resource == resource &&
          other.epoch == epoch &&
          other.blockId == blockId &&
          other.blockVersion == blockVersion &&
          other.textLength == textLength &&
          other.parserVersion == parserVersion &&
          other.syntaxConfig == syntaxConfig;

  @override
  int get hashCode => Object.hash(
    resource,
    epoch,
    blockId,
    blockVersion,
    textLength,
    parserVersion,
    syntaxConfig,
  );

  @override
  String toString() => '$resource#$blockId@$blockVersion($textLength chars)';
}

/// One memoized prepared block plus the dependency state it was built from.
final class MarkdownBlockMemo {
  MarkdownBlockMemo({
    required this.key,
    required this.payload,
    required this.bytes,
    required Map<BlockReference, int> referenceVersions,
    required this.textFingerprint,
  }) : referenceVersions = Map<BlockReference, int>.unmodifiable(
         referenceVersions,
       );

  final MarkdownBlockMemoKey key;
  final MessageMarkdownBlock payload;
  final int bytes;

  /// Length of the source text this memo was prepared from.
  int get textLength => key.textLength;

  /// Versions of the declared references when this block was prepared.
  final Map<BlockReference, int> referenceVersions;

  /// Fingerprint of the source text this block was parsed from, used only by
  /// strict verification.
  final int textFingerprint;

  @override
  String toString() =>
      'MarkdownBlockMemo(${key.blockId}@${key.blockVersion}, ${bytes}B)';
}

/// What one block was last prepared as.
final class MarkdownKnownBlock {
  const MarkdownKnownBlock({required this.version, required this.textLength});

  final BlockVersion version;
  final int textLength;
}

/// Last observed preparation state of one resource.
final class MarkdownResourcePreparationState {
  const MarkdownResourcePreparationState({
    required this.epoch,
    required this.parserVersion,
    required this.syntaxConfig,
    this.replaced = false,
  });

  /// State after a source was replaced but before anything was prepared from
  /// the new source: the next attempt must re-parse everything.
  const MarkdownResourcePreparationState.replaced(this.epoch)
    : parserVersion = null,
      syntaxConfig = null,
      replaced = true;

  final SourceEpoch epoch;
  final ParserVersion? parserVersion;
  final SyntaxConfig? syntaxConfig;
  final bool replaced;
}

/// A byte-bounded cache of prepared Markdown.
///
/// One budget covers both prepared blocks and whole prepared values, so the
/// resident set is bounded by [capacityBytes] however a source streams. Block
/// memos are evicted least-recently-used first, and a block whose prepared
/// payload was evicted is simply parsed again.
final class MarkdownPreparationCache {
  MarkdownPreparationCache({
    this.capacityBytes = defaultMarkdownPreparationCacheBytes,
  }) {
    _lru = ByteLruCache<_CacheKey, _CacheValue>(
      capacityBytes: capacityBytes,
      onRemoved: _onRemoved,
    );
  }

  final int capacityBytes;

  /// One budget covers block memos and whole prepared values, so eviction of
  /// either kind frees room for the other.
  late final ByteLruCache<_CacheKey, _CacheValue> _lru;
  final LinkedHashMap<BlockReference, int> _referenceVersions =
      LinkedHashMap<BlockReference, int>();
  final LinkedHashMap<MarkdownBlockIdentity, MarkdownKnownBlock> _knownBlocks =
      LinkedHashMap<MarkdownBlockIdentity, MarkdownKnownBlock>();
  final Map<ResourceKey, MarkdownResourcePreparationState> _resourceStates =
      <ResourceKey, MarkdownResourcePreparationState>{};
  int _blockMemos = 0;
  int _preparedValues = 0;
  bool _referenceOverflow = false;

  int get residentBytes => _lru.residentBytes;

  int get blockMemos => _blockMemos;

  int get preparedValues => _preparedValues;

  int get evictions => _lru.evictions;

  int get rejectedPuts => _lru.rejectedPuts;

  /// True when a prepared payload of [bytes] can be admitted at all.
  bool fits(int bytes) => bytes <= capacityBytes;

  MarkdownBlockMemo? blockMemo(MarkdownBlockMemoKey key) {
    final value = _lru.get(_BlockKey(key));
    return value is _BlockMemoValue ? value.memo : null;
  }

  void putBlock(
    MarkdownBlockMemoKey key,
    MessageMarkdownBlock payload,
    int bytes, {
    required Map<BlockReference, int> referenceVersions,
    int textFingerprint = 0,
  }) {
    if (!fits(bytes)) {
      // A single block larger than the whole budget is never admitted, so the
      // cache never reports bytes it does not hold.
      return;
    }
    final cacheKey = _BlockKey(key);
    final resident = _lru.containsKey(cacheKey);
    final result = _lru.put(
      cacheKey,
      _BlockMemoValue(
        MarkdownBlockMemo(
          key: key,
          payload: payload,
          bytes: bytes,
          referenceVersions: referenceVersions,
          textFingerprint: textFingerprint,
        ),
      ),
      bytes: bytes,
    );
    if (result.stored && !resident) _blockMemos++;
    _rememberBlock(key);
  }

  /// What this cache last prepared for one block, if anything.
  MarkdownKnownBlock? knownBlock(MarkdownBlockIdentity identity) =>
      _knownBlocks[identity];

  /// True when this exact block text was prepared before and is no longer
  /// resident: the re-parse is attributable to eviction, not to a source edit.
  bool wasEvicted(MarkdownBlockMemoKey key) {
    final known = _knownBlocks[key.identity];
    return known != null &&
        known.version == key.blockVersion &&
        known.textLength == key.textLength;
  }

  PreparedValue<MessageMarkdownBlock>? preparedValue(PreparationKey key) {
    final value = _lru.get(_ValueKey(key));
    return value is _PreparedValueValue ? value.value : null;
  }

  void putPreparedValue(
    PreparationKey key,
    PreparedValue<MessageMarkdownBlock> value,
    int bytes,
  ) {
    if (!fits(bytes)) return;
    final cacheKey = _ValueKey(key);
    final resident = _lru.containsKey(cacheKey);
    final result = _lru.put(cacheKey, _PreparedValueValue(value), bytes: bytes);
    if (result.stored && !resident) _preparedValues++;
  }

  /// Current dependency version of one referenced block.
  int referenceVersion(BlockReference reference) =>
      _referenceVersions[reference] ?? 0;

  /// Marks a referenced block as changed for every block that depends on it.
  ///
  /// Recording one explicit [version] twice is idempotent, so planning the same
  /// revision repeatedly cannot keep invalidating its own dependents.
  int invalidateBlock(BlockReference reference, {int? version}) {
    final current = _referenceVersions[reference];
    if (version != null && current != null && current >= version) {
      return current;
    }
    if (_referenceVersions.length >= _referenceVersionCapacity &&
        current == null) {
      // Forget every remembered dependency version rather than trust a
      // dependency this cache can no longer name.
      _referenceVersions.clear();
      _referenceOverflow = true;
    }
    final next = version ?? ((current ?? 0) + 1);
    _referenceVersions.remove(reference);
    _referenceVersions[reference] = next;
    return next;
  }

  /// True when a dependency version was forgotten, so dependents re-parse once.
  bool get referenceVersionsOverflowed => _referenceOverflow;

  void clearReferenceOverflow() => _referenceOverflow = false;

  MarkdownResourcePreparationState? resourceState(ResourceKey resource) =>
      _resourceStates[resource];

  void rememberResourceState(
    ResourceKey resource,
    MarkdownResourcePreparationState state,
  ) {
    _resourceStates.remove(resource);
    _resourceStates[resource] = state;
  }

  /// Drops everything prepared for a resource whose source was replaced.
  ///
  /// Offsets and block identities of the old source are meaningless in the new
  /// one, so the resource starts over rather than reuse anything.
  void replaceSource(ResourceKey resource, SourceEpoch epoch) {
    _dropResource(resource);
    _resourceStates[resource] = MarkdownResourcePreparationState.replaced(
      epoch,
    );
  }

  /// Drops prepared state for one resource.
  int dropResource(ResourceKey resource) => _dropResource(resource);

  int _dropResource(ResourceKey resource) {
    return _lru.removeWhere((key, _) => _resourceOf(key) == resource);
  }

  void clear() {
    _lru.clear(force: true);
    _referenceVersions.clear();
    _knownBlocks.clear();
    _resourceStates.clear();
    _referenceOverflow = false;
  }

  void _rememberBlock(MarkdownBlockMemoKey key) {
    if (_knownBlocks.length >= _knownBlockCapacity &&
        !_knownBlocks.containsKey(key.identity)) {
      _knownBlocks.remove(_knownBlocks.keys.first);
    }
    _knownBlocks.remove(key.identity);
    _knownBlocks[key.identity] = MarkdownKnownBlock(
      version: key.blockVersion,
      textLength: key.textLength,
    );
  }

  void _onRemoved(_CacheKey key, _CacheValue _) {
    switch (key) {
      case _BlockKey():
        _blockMemos--;
      case _ValueKey():
        _preparedValues--;
    }
  }

  ResourceKey _resourceOf(_CacheKey key) => switch (key) {
    _BlockKey(memo: final memo) => memo.resource,
    _ValueKey(key: final preparation) => preparation.content.resource,
  };

  String describe() =>
      'MarkdownPreparationCache(${_lru.residentBytes}/$capacityBytes bytes, '
      '${_blockMemos} block memos, $_preparedValues values, '
      '${_lru.evictions} evictions)';
}

sealed class _CacheKey {
  const _CacheKey();
}

final class _BlockKey extends _CacheKey {
  const _BlockKey(this.memo);

  final MarkdownBlockMemoKey memo;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is _BlockKey && other.memo == memo;

  @override
  int get hashCode => memo.hashCode;
}

final class _ValueKey extends _CacheKey {
  const _ValueKey(this.key);

  final PreparationKey key;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is _ValueKey && other.key == key;

  @override
  int get hashCode => key.hashCode;
}

sealed class _CacheValue {
  const _CacheValue();
}

final class _BlockMemoValue extends _CacheValue {
  const _BlockMemoValue(this.memo);

  final MarkdownBlockMemo memo;
}

final class _PreparedValueValue extends _CacheValue {
  const _PreparedValueValue(this.value);

  final PreparedValue<MessageMarkdownBlock> value;
}
