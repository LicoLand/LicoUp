import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import '../../cache/markdown_preparation_cache.dart';
import '../../scheduling/preparation_cancellation.dart';
import '../../scheduling/preparation_executor.dart' show PreparationPriority;
import '../../scheduling/preparation_worker.dart';
import '../../scheduling/preparation_worker_pool.dart';
import 'message_markdown_decomposition.dart';
import 'message_markdown_models.dart';
import 'message_markdown_parser.dart';

/// Worker operation name for one batch of Markdown block regions.
const String markdownRegionOperation = 'markdown.region';

/// Worker operation name for one whole-message block scan.
const String markdownScanOperation = 'markdown.scan';

/// Parser identity published with this engine's output semantics.
///
/// v2 adds the prepared inline display runs to every block payload, so a value
/// prepared by v1 cannot be reused as a v2 value.
const ParserVersion defaultMarkdownParserVersion = ParserVersion(
  'licoup.markdown.blocks.v2',
);

/// Semantic Markdown configuration used when a caller does not supply one.
///
/// Styling has no field here, so a restyle cannot invalidate a prepared value;
/// only this revision and its feature set can.
final SyntaxConfig defaultMarkdownSyntaxConfig = SyntaxConfig(
  revision: 'licoup.markdown.default',
  features: const <String>['fences', 'tables', 'quotes', 'lists'],
);

/// One parse batch executed inside a worker isolate.
///
/// Payload shape: `[yieldBudgetBytes, regions]` where each region is
/// `[blockId, text]`. Result shape: a list of `[blockId, errorCode, payload]`,
/// so one bad region is reported without discarding the good ones.
Future<Object?> runMarkdownRegionParse(
  Object? payload,
  WorkerJobContext context,
) async {
  final batch = payload! as List<Object?>;
  final yieldBudgetBytes = batch[0]! as int;
  final regions = batch[1]! as List<Object?>;
  final results = <Object?>[];
  var bytesSinceYield = 0;
  for (final entry in regions) {
    if (context.isCancelled) {
      throw const PreparationCancelledException(
        PreparationCancellationReason.superseded,
        stage: 'region',
      );
    }
    final region = entry! as List<Object?>;
    final blockId = region[0]! as String;
    final text = region[1]! as String;
    context.recordWorkBytes(text.length);
    try {
      final block = parseMessageMarkdownBlockRegion(text);
      results.add(<Object?>[blockId, null, encodeMessageMarkdownBlock(block)]);
    } on PreparationWorkerException catch (failure) {
      results.add(<Object?>[blockId, failure.code, null]);
    }
    bytesSinceYield += text.length;
    if (bytesSinceYield >= yieldBudgetBytes) {
      bytesSinceYield = 0;
      await context.yieldToControl();
    }
  }
  return results;
}

/// Everything one preparation attempt needs to be scheduled and installed.
final class MarkdownPreparationRequest {
  MarkdownPreparationRequest({
    required this.preparedField,
    required this.revision,
    required this.generation,
    SyntaxConfig? syntaxConfig,
    this.consistencyGroup,
    this.priority = PreparationPriority.foreground,
  }) : syntaxConfig = syntaxConfig ?? defaultMarkdownSyntaxConfig,
       assert(
         preparedField.resource == revision.resource,
         'the prepared field and the source text must share one resource',
       );

  /// The prepared field group this attempt produces.
  final ResourceFieldGroup<PreparedValue<MessageMarkdownBlock>> preparedField;

  /// The source revision being prepared.
  final MessageMarkdownDecomposition revision;

  final RequestGeneration generation;
  final SyntaxConfig syntaxConfig;

  /// Consistency group this attempt belongs to, when the source reported one.
  final ConsistencyGroup? consistencyGroup;

  final PreparationPriority priority;

  ResourceKey get resource => revision.resource;

  @override
  String toString() =>
      'MarkdownPreparationRequest(${preparedField.name}@${revision.position})';
}

/// What one attempt would do, computed without running any parse.
final class MarkdownPreparationPlan {
  const MarkdownPreparationPlan({
    required this.trigger,
    required this.scope,
    required this.cause,
    required this.blocksToParse,
    required this.reusableBlocks,
    required this.changedBlocks,
    required this.reusedValue,
    required this.estimatedInputBytes,
  });

  /// Why this attempt has to run. Null when nothing has to run at all.
  final PreparationTrigger? trigger;
  final PreparationScope? scope;
  final PreparationCause? cause;

  final List<BlockId> blocksToParse;
  final List<BlockId> reusableBlocks;

  /// Blocks whose own text changed, reported as [PreparationCause.changed].
  final Set<BlockId> changedBlocks;

  /// True when the exact prepared value was already resident, so this attempt
  /// is pure reuse: no parse, no assembly, and the identical value comes back.
  final bool reusedValue;

  final int estimatedInputBytes;

  bool get requiresRePreparation => !reusedValue;

  bool get requiresWorker => blocksToParse.isNotEmpty;

  @override
  String toString() =>
      'MarkdownPreparationPlan(parse: ${blocksToParse.length}, '
      'reuse: ${reusableBlocks.length}, trigger: $trigger, scope: $scope)';
}

/// Result of one preparation attempt, with the evidence it produced.
final class MarkdownPreparationOutcome {
  const MarkdownPreparationOutcome({
    required this.result,
    required this.plan,
    required this.parsedBlocks,
    required this.bytes,
    required this.residentBytes,
    required this.worker,
    required this.elapsed,
  });

  final PreparedResource<PreparedValue<MessageMarkdownBlock>> result;
  final MarkdownPreparationPlan plan;

  /// Blocks actually parsed by a worker for this attempt.
  final int parsedBlocks;

  /// Bytes of prepared payload this value covers.
  final int bytes;

  /// Cache bytes resident after this attempt.
  final int residentBytes;

  /// Which worker isolate produced the parse. Null when nothing was parsed.
  final PreparationWorkerIdentity? worker;

  final Duration elapsed;

  PreparedValue<MessageMarkdownBlock> get value => result.value;

  PreparationRequest<PreparedValue<MessageMarkdownBlock>> get request =>
      result.request;

  bool get reusedExistingValue => plan.reusedValue;

  @override
  String toString() =>
      'MarkdownPreparationOutcome(parsed: $parsedBlocks, bytes: $bytes, '
      'worker: $worker, cause: ${plan.cause})';
}

/// Result of one off-thread decomposition.
final class MarkdownDecompositionOutcome {
  const MarkdownDecompositionOutcome({
    required this.revision,
    required this.worker,
    required this.scannedBlocks,
    required this.inputLength,
    required this.elapsed,
  });

  /// The revision built from the worker's scan.
  final MessageMarkdownDecomposition revision;

  /// Which worker isolate performed the scan.
  final PreparationWorkerIdentity worker;

  /// Blocks the scan described.
  final int scannedBlocks;

  /// UTF-16 code units of the text the worker scanned, the same unit the
  /// worker reports for the work it did.
  final int inputLength;

  final Duration elapsed;

  @override
  String toString() =>
      'MarkdownDecompositionOutcome(${revision.resource}@${revision.position}, '
      '${revision.blocks.length} blocks, worker: $worker)';
}

/// Per-message incremental Markdown preparation.
///
/// The engine decides which blocks need parsing from the preparation key,
/// declared block versions, and declared cross-block references, then runs the
/// parse in a real worker isolate. A block that is still open, a block whose
/// referenced block changed, and a block whose payload was evicted all re-parse;
/// everything else is reused without reading its text again.
final class MarkdownPreparationEngine {
  MarkdownPreparationEngine({
    required this.workers,
    MarkdownPreparationCache? cache,
    this.parserVersion = defaultMarkdownParserVersion,
    this.yieldBudgetBytes = 64 * 1024,
    this.strictTextVerification = false,
  }) : cache = cache ?? MarkdownPreparationCache();

  /// Operations a pool must be spawned with to serve this engine.
  static Map<String, PreparationWorkerOperation> get workerOperations =>
      <String, PreparationWorkerOperation>{
        markdownRegionOperation: runMarkdownRegionParse,
        markdownScanOperation: runMarkdownScan,
      };

  /// Convenience constructor: a pool sized by a real throughput probe.
  static Future<MarkdownPreparationEngine> spawnMeasured({
    String name = 'markdown',
    MarkdownPreparationCache? cache,
    int maxCandidates = 2,
    int probeJobs = 3,
  }) async {
    final pool = await PreparationWorkerPool.spawnMeasured(
      name: name,
      operations: workerOperations,
      workloadOperation: markdownRegionOperation,
      workloadPayload: <Object?>[
        64 * 1024,
        <Object?>[
          <Object?>['probe-block', '# Probe\n\nprobe body for a measured pool'],
        ],
      ],
      probeJobs: probeJobs,
      maxCandidates: maxCandidates,
    );
    return MarkdownPreparationEngine(workers: pool, cache: cache);
  }

  final PreparationWorkerPool workers;
  final MarkdownPreparationCache cache;
  final ParserVersion parserVersion;

  /// Bytes a worker parses before handing control back to its event loop.
  final int yieldBudgetBytes;

  /// When enabled, a memo is only reused when the source text it was built from
  /// still matches. Off by default because it re-reads every block's text; the
  /// default trusts the source's block version, which is the F0 contract.
  final bool strictTextVerification;

  /// Scans one message revision into source blocks, in a worker isolate.
  ///
  /// This is the off-thread form of `decomposeMessageMarkdown`: the calling
  /// isolate sends the text and receives compact block descriptors, then
  /// derives identity, versions, and references without parsing, splitting
  /// lines, or normalizing anything itself. The revision it returns feeds
  /// [prepare] exactly like a locally decomposed one.
  ///
  /// The scan is one job per revision: block boundaries need whole-document
  /// context, so the text crosses the boundary once and the reply carries only
  /// descriptors. Cancellation is observed between blocks, the same cooperative
  /// boundary the region operation uses.
  Future<MarkdownDecompositionOutcome> decompose({
    required ResourceKey resource,
    required SourcePosition position,
    required String text,
    MessageMarkdownDecomposition? previous,
    String idPrefix = 'block',
    MarkdownLabelReferenceResolver? resolveExternalLabel,
    PreparationCancellationToken? cancel,
    PreparationPriority priority = PreparationPriority.foreground,
    void Function(PreparationWorkerIdentity identity)? onWorker,
  }) async {
    final watch = Stopwatch()..start();
    PreparationWorkerIdentity? worker;
    final raw = await workers.execute(
      operation: markdownScanOperation,
      payload: <Object?>[yieldBudgetBytes, text],
      cancel: cancel,
      priority: priority,
      onWorker: (identity) {
        worker = identity;
        onWorker?.call(identity);
      },
    );
    if (cancel?.isCancelled ?? false) {
      throw PreparationCancelledException(cancel!.reason!, stage: 'scan');
    }
    if (raw is! List<Object?>) {
      throw const PreparationWorkerException(
        code: 'markdown.scan_invalid',
        detail: 'worker did not return a block scan',
      );
    }
    final identity = worker;
    if (identity == null) {
      throw const PreparationWorkerException(
        code: 'markdown.scan_worker_missing',
        detail: 'scan completed without a worker identity',
      );
    }
    final scanned = <ScannedMarkdownBlock>[
      for (final entry in raw) decodeScannedMarkdownBlock(entry),
    ];
    return MarkdownDecompositionOutcome(
      revision: assembleMessageMarkdownDecomposition(
        resource: resource,
        position: position,
        text: text,
        blocks: scanned,
        previous: previous,
        idPrefix: idPrefix,
        resolveExternalLabel: resolveExternalLabel,
      ),
      worker: identity,
      scannedBlocks: scanned.length,
      inputLength: text.length,
      elapsed: watch.elapsed,
    );
  }

  /// Computes what an attempt would do, without running any parse.
  ///
  /// A block that changed since its last preparation is recorded in the
  /// dependency index (idempotently), so blocks that read it re-parse next time
  /// even when they live in another message.
  MarkdownPreparationPlan plan(MarkdownPreparationRequest request) {
    final revision = request.revision;
    final key = _keyFor(request);
    if (_valueStillReusable(request, cache.preparedValue(key))) {
      return MarkdownPreparationPlan(
        trigger: null,
        scope: null,
        cause: null,
        blocksToParse: const <BlockId>[],
        reusableBlocks: revision.blockIds,
        changedBlocks: const <BlockId>{},
        reusedValue: true,
        estimatedInputBytes: 0,
      );
    }

    final state = cache.resourceState(revision.resource);
    final epochReplaced = state != null && state.replaced;
    final configChanged =
        state != null &&
        !state.replaced &&
        state.epoch == revision.position.epoch &&
        (state.parserVersion != parserVersion ||
            state.syntaxConfig != request.syntaxConfig);
    final overflow = cache.referenceVersionsOverflowed;

    final changed = <BlockId>{};
    for (final block in revision.blocks) {
      final known = cache
          .knownBlock(MarkdownBlockIdentity(revision.resource, block.id))
          ?.version;
      if (known != null && known != block.version) {
        // This block's own text changed, so every block that references it
        // re-parses, in this message or in another one.
        cache.invalidateBlock(
          BlockReference(resource: revision.resource, blockId: block.id),
          version: known.value + 1,
        );
      }
    }

    final toParse = <BlockId>[];
    final reusable = <BlockId>[];
    var inputBytes = 0;
    var dependencyChanged = false;
    var evicted = false;
    for (final block in revision.blocks) {
      final memoKey = _memoKeyFor(request, block);
      final memo = cache.blockMemo(memoKey);
      if (memo == null) {
        toParse.add(block.id);
        inputBytes += block.text.range.length;
        if (cache.wasEvicted(memoKey)) {
          evicted = true;
        } else {
          changed.add(block.id);
        }
        continue;
      }
      if (!block.isSealed) {
        // An open fence, a table a following row could still extend, or a
        // paragraph running to the end of the text: not final yet.
        toParse.add(block.id);
        inputBytes += block.text.range.length;
        changed.add(block.id);
        continue;
      }
      if (overflow ||
          (strictTextVerification &&
              !_matchesMemoText(memo, revision, block)) ||
          !_sameReferenceVersions(memo, block)) {
        toParse.add(block.id);
        inputBytes += block.text.range.length;
        dependencyChanged = true;
        continue;
      }
      reusable.add(block.id);
    }

    final PreparationTrigger trigger;
    if (epochReplaced) {
      trigger = PreparationTrigger.sourceReplaced;
    } else if (configChanged) {
      trigger = PreparationTrigger.parserConfigChanged;
    } else if (overflow || dependencyChanged) {
      trigger = PreparationTrigger.blockDependencyChanged;
    } else if (toParse.isEmpty) {
      trigger = PreparationTrigger.cacheEvicted;
    } else if (evicted) {
      trigger = PreparationTrigger.cacheEvicted;
    } else if (reusable.isEmpty) {
      trigger = PreparationTrigger.initial;
    } else {
      trigger = PreparationTrigger.blocksChanged;
    }
    final global =
        epochReplaced ||
        configChanged ||
        overflow ||
        (toParse.isNotEmpty && reusable.isEmpty);
    final scope = global
        ? PreparationScope.global
        : PreparationScope.incremental;
    return MarkdownPreparationPlan(
      trigger: trigger,
      scope: scope,
      cause: PreparationCause(trigger: trigger, scope: scope, changed: changed),
      blocksToParse: List<BlockId>.unmodifiable(toParse),
      reusableBlocks: List<BlockId>.unmodifiable(reusable),
      changedBlocks: Set<BlockId>.unmodifiable(changed),
      reusedValue: false,
      estimatedInputBytes: inputBytes,
    );
  }

  /// Prepares one message revision, parsing only what changed.
  Future<MarkdownPreparationOutcome> prepare(
    MarkdownPreparationRequest request, {
    PreparationCancellationToken? cancel,
  }) async {
    final watch = Stopwatch()..start();
    final revision = request.revision;
    final key = _keyFor(request);
    final residentValue = cache.preparedValue(key);
    final attempt = plan(request);
    if (attempt.reusedValue) {
      cache.clearReferenceOverflow();
      return MarkdownPreparationOutcome(
        result: PreparedResource<PreparedValue<MessageMarkdownBlock>>(
          request: _requestFor(request, null),
          value: residentValue!,
        ),
        plan: attempt,
        parsedBlocks: 0,
        bytes: _valueBytes(residentValue),
        residentBytes: cache.residentBytes,
        worker: null,
        elapsed: watch.elapsed,
      );
    }

    final parsed = <BlockId, MessageMarkdownBlock>{};
    PreparationWorkerIdentity? worker;
    if (attempt.blocksToParse.isNotEmpty) {
      final regions = <Object?>[
        for (final blockId in attempt.blocksToParse)
          <Object?>[
            blockId.value,
            revision.textOf(_blockOf(revision, blockId)),
          ],
      ];
      final raw = await workers.execute(
        operation: markdownRegionOperation,
        payload: <Object?>[yieldBudgetBytes, regions],
        cancel: cancel,
        priority: request.priority,
        onWorker: (identity) => worker = identity,
      );
      if (raw is! List<Object?>) {
        throw const PreparationWorkerException(
          code: 'markdown.region_batch_invalid',
          detail: 'worker did not return a region batch',
        );
      }
      for (final entry in raw) {
        final result = entry! as List<Object?>;
        final blockId = BlockId(result[0]! as String);
        final errorCode = result[1];
        if (errorCode != null) {
          throw PreparationWorkerException(
            code: errorCode as String,
            detail: 'block ${blockId.value} of ${revision.resource}',
          );
        }
        parsed[blockId] = decodeMessageMarkdownBlock(result[2]);
      }
    }

    if (cancel?.isCancelled ?? false) {
      throw PreparationCancelledException(cancel!.reason!, stage: 'install');
    }

    final preparedBlocks = <PreparedBlock<MessageMarkdownBlock>>[];
    var bytes = 0;
    for (final block in revision.blocks) {
      final payload =
          parsed[block.id] ??
          cache.blockMemo(_memoKeyFor(request, block))?.payload;
      if (payload == null) {
        throw PreparationWorkerException(
          code: 'markdown.block_not_prepared',
          detail: 'block ${block.id.value} of ${revision.resource}',
        );
      }
      bytes += messageMarkdownBlockBytes(payload);
      preparedBlocks.add(
        PreparedBlock<MessageMarkdownBlock>(block: block, value: payload),
      );
    }

    for (final block in revision.blocks) {
      final payload = parsed[block.id];
      if (payload == null || !block.isSealed) continue;
      cache.putBlock(
        _memoKeyFor(request, block),
        payload,
        messageMarkdownBlockBytes(payload),
        referenceVersions: _observedReferenceVersions(block),
        textFingerprint: _fingerprint(revision.textOf(block)),
      );
    }

    final value = PreparedValue<MessageMarkdownBlock>.fromBlocks(
      key: key,
      blocks: preparedBlocks,
      referencedInputs: _referencedInputs(revision),
    );
    cache.putPreparedValue(key, value, bytes);
    cache.rememberResourceState(
      revision.resource,
      MarkdownResourcePreparationState(
        epoch: revision.position.epoch,
        parserVersion: parserVersion,
        syntaxConfig: request.syntaxConfig,
      ),
    );
    cache.clearReferenceOverflow();
    return MarkdownPreparationOutcome(
      result: PreparedResource<PreparedValue<MessageMarkdownBlock>>(
        request: _requestFor(request, attempt.cause),
        value: value,
      ),
      plan: attempt,
      parsedBlocks: parsed.length,
      bytes: bytes,
      residentBytes: cache.residentBytes,
      worker: worker,
      elapsed: watch.elapsed,
    );
  }

  /// Drops prepared state for a resource whose source was replaced.
  ///
  /// The next attempt for this resource re-parses everything and records
  /// [PreparationTrigger.sourceReplaced].
  void replaceSource(ResourceKey resource, SourceEpoch epoch) =>
      cache.replaceSource(resource, epoch);

  /// Marks a referenced block as changed, so every dependent re-prepares.
  ///
  /// A source that observes a change outside this engine's own prepare path,
  /// such as a link definition in an interleaved message, uses this to
  /// invalidate the blocks that read it.
  int invalidateBlock(ResourceKey resource, BlockId blockId, {int? version}) =>
      cache.invalidateBlock(
        BlockReference(resource: resource, blockId: blockId),
        version: version,
      );

  PreparationRequest<PreparedValue<MessageMarkdownBlock>> _requestFor(
    MarkdownPreparationRequest request,
    PreparationCause? cause,
  ) {
    return PreparationRequest<PreparedValue<MessageMarkdownBlock>>(
      resource: request.preparedField,
      source: request.revision.position,
      generation: request.generation,
      consistencyGroup: request.consistencyGroup,
      cause: cause,
    );
  }

  PreparationKey _keyFor(MarkdownPreparationRequest request) => PreparationKey(
    parserVersion: parserVersion,
    syntaxConfig: request.syntaxConfig,
    content: request.revision.toContentRevision(),
  );

  MarkdownBlockMemoKey _memoKeyFor(
    MarkdownPreparationRequest request,
    SourceBlock block,
  ) => MarkdownBlockMemoKey(
    resource: request.revision.resource,
    epoch: request.revision.position.epoch,
    blockId: block.id,
    blockVersion: block.version,
    textLength: block.text.range.length,
    parserVersion: parserVersion,
    syntaxConfig: request.syntaxConfig,
  );

  Map<BlockReference, int> _observedReferenceVersions(SourceBlock block) =>
      <BlockReference, int>{
        for (final reference in block.references)
          reference: cache.referenceVersion(reference),
      };

  bool _sameReferenceVersions(MarkdownBlockMemo memo, SourceBlock block) {
    final observed = _observedReferenceVersions(block);
    if (observed.length != memo.referenceVersions.length) return false;
    for (final entry in observed.entries) {
      if (memo.referenceVersions[entry.key] != entry.value) return false;
    }
    return true;
  }

  /// A resident value is only reused while the dependency versions it was
  /// prepared against are still current: a block that reads another block can
  /// be stale even when its own text never changed.
  bool _valueStillReusable(
    MarkdownPreparationRequest request,
    PreparedValue<MessageMarkdownBlock>? value,
  ) {
    if (value == null) return false;
    if (cache.referenceVersionsOverflowed) return false;
    for (final block in request.revision.blocks) {
      if (block.references.isEmpty) continue;
      final memo = cache.blockMemo(_memoKeyFor(request, block));
      if (memo == null || !_sameReferenceVersions(memo, block)) return false;
    }
    return true;
  }

  bool _matchesMemoText(
    MarkdownBlockMemo memo,
    MessageMarkdownDecomposition revision,
    SourceBlock block,
  ) =>
      memo.textFingerprint != 0 &&
      memo.textFingerprint == _fingerprint(revision.textOf(block));

  /// Cross-message block references are declared as inputs, so a consumer can
  /// see which other messages a prepared value reads.
  Set<PreparedInputReference> _referencedInputs(
    MessageMarkdownDecomposition revision,
  ) {
    return <PreparedInputReference>{
      for (final block in revision.blocks)
        for (final reference in block.references)
          PreparedInputReference(
            resource: reference.resource,
            name: reference.blockId.value,
          ),
    };
  }

  SourceBlock _blockOf(MessageMarkdownDecomposition revision, BlockId id) {
    final block = revision.block(id);
    if (block == null) {
      throw PreparationWorkerException(
        code: 'markdown.block_not_in_revision',
        detail: 'block ${id.value} of ${revision.resource}',
      );
    }
    return block;
  }

  int _valueBytes(PreparedValue<MessageMarkdownBlock> value) {
    var bytes = 0;
    for (final block in value.blocks) {
      bytes += messageMarkdownBlockBytes(block.value);
    }
    return bytes;
  }
}

/// FNV-1a over UTF-16 code units, used only by strict text verification.
int _fingerprint(String value) {
  var hash = 0x811c9dc5;
  for (var index = 0; index < value.length; index++) {
    hash = (hash ^ value.codeUnitAt(index)) & 0xFFFFFFFF;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash == 0 ? 1 : hash;
}
