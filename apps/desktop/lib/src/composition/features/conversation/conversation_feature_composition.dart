import 'dart:async';

import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/composition/renderer_intent_trace.dart';
import 'package:licoup/src/contracts/agent_conversation_attachment.dart';
import 'package:licoup/src/contracts/conversation_image_byte_reader.dart';
import 'package:licoup/src/presentation/conversation/conversation_binding.dart';
import 'package:licoup/src/presentation/conversation/conversation_effect.dart';
import 'package:licoup/src/presentation/conversation/conversation_intent.dart';
import 'package:licoup/src/projections/conversation/conversation_projection_producer.dart';

final class ConversationFeatureComposition {
  ConversationFeatureComposition(
    ClientController controller, {
    RendererIntentTraceFactory? beginRendererIntent,
  }) : _projection = ConversationProjectionProducer(controller),
       _effects = _ConversationEffects() {
    _intents = _ConversationIntents(
      controller,
      _projection,
      _effects,
      beginRendererIntent: beginRendererIntent,
    );
    binding = ConversationBinding(
      projection: _projection.projection,
      nativeCatalog: _projection.nativeCatalog,
      canonicalEvents: _projection.canonicalEvents,
      persistentTurns: _projection.persistentTurns,
      composer: _projection.composer,
      attachments: _projection.attachments,
      tabActivity: _projection.tabActivity,
      notifications: _projection.notifications,
      archive: _projection.archive,
      intents: _intents,
      effects: _effects,
    );
  }

  final ConversationProjectionProducer _projection;
  final _ConversationEffects _effects;
  late final _ConversationIntents _intents;
  late final ConversationBinding binding;
  bool _closed = false;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _intents.close();
    await _projection.close();
    await _effects.close();
  }
}

final class _ConversationEffects implements EffectSource<ConversationEffect> {
  final StreamController<ConversationEffect> _controller =
      StreamController<ConversationEffect>.broadcast(sync: true);

  @override
  Stream<ConversationEffect> get effects => _controller.stream;

  void add(ConversationEffect effect) => _controller.add(effect);

  Future<void> close() => _controller.close();
}

final class _ConversationIntents implements IntentSink<ConversationIntent> {
  _ConversationIntents(
    this._controller,
    this._projection,
    this._effects, {
    RendererIntentTraceFactory? beginRendererIntent,
  }) : _beginRendererIntent = beginRendererIntent;

  final ClientController _controller;
  final ConversationProjectionProducer _projection;
  final _ConversationEffects _effects;
  final RendererIntentTraceFactory? _beginRendererIntent;

  void close() => _controller.providerQuotaController.releasePollingOwner(this);

  @override
  void send(ConversationIntent intent) {
    final trace = resolveRendererIntentTrace(
      intent.trace,
      _beginRendererIntent,
    );
    switch (intent) {
      case RefreshConversationCatalog(:final agentId):
        final requestedAgentId = agentId.trim();
        if (requestedAgentId.isNotEmpty) {
          _run(
            () => _controller.refreshConversationSessions(requestedAgentId),
            trace,
            stage: 'catalog-prefetch',
          );
          break;
        }
        final selectedAgentId = _controller.selectedConversationAgentId.trim();
        if (selectedAgentId.isNotEmpty) {
          _run(
            () => _controller.refreshConversationSessions(selectedAgentId),
            trace,
            stage: 'catalog-refresh',
          );
        }
        _run(
          _controller.clientConversationController.refresh,
          trace,
          stage: 'canonical-refresh',
        );
      case LoadMoreConversationSessions():
        _run(
          () => _controller.loadMoreConversationSessions(
            _controller.selectedConversationAgentId,
          ),
          trace,
          stage: 'catalog-load-more',
        );
      case SelectConversationSession(:final sessionId):
        _controller.clientConversationController.clearSelection();
        _controller.selectConversationSession(sessionId);
      case SelectCanonicalConversation(:final conversationId):
        _run(
          () => _controller.clientConversationController.selectConversation(
            conversationId,
          ),
          trace,
          stage: 'canonical-select',
        );
      case ClearCanonicalConversationSelection():
        _controller.clientConversationController.clearSelection();
      case CreateCanonicalConversationGroup(:final title, :final members):
        _runResult(
          () => _controller.clientConversationController.createGroup(
            title: title,
            members: members,
          ),
          trace,
          stage: 'canonical-create',
          onSuccess: () {
            _effects.add(
              CanonicalConversationGroupCreated(
                _controller.clientConversationController.selectedConversationId,
                trace: trace,
              ),
            );
          },
        );
      case StartConversationSession():
        _controller.clientConversationController.clearSelection();
        _controller.startNewConversationSession();
      case LoadEarlierConversationEvents():
        if (_controller
            .clientConversationController
            .selectedConversationId
            .isNotEmpty) {
          _run(
            () async {
              await _controller.clientConversationController.reloadSelected();
            },
            trace,
            stage: 'canonical-load-earlier',
          );
        } else {
          _run(
            _controller.loadEarlierConversationMessages,
            trace,
            stage: 'native-load-earlier',
          );
        }
      case PostConversationMessage(
        :final conversationId,
        :final content,
        :final dispatchCanonical,
      ):
        _post(conversationId, content, dispatchCanonical, trace);
      case UpdateConversationDraft(:final conversationId, :final draft):
        _controller.conversationPresentationSignals.replaceComposerDraft(
          conversationId,
          draft,
        );
        _projection.publishLocalChange(trace: trace);
      case CopyConversationText(:final text):
        _run(
          () => _controller.clientClipboardService.writeText(text),
          trace,
          stage: 'copy',
        );
      case AddConversationAttachment(:final conversationId):
        _effects.add(
          ConversationAttachmentSelectionRequested(
            conversationId,
            trace: trace,
          ),
        );
      case PasteConversationAttachment(:final conversationId):
        _runPasteAttachment(conversationId, trace);
      case StageConversationAttachments(
        :final conversationId,
        :final attachments,
      ):
        _runStageAttachments(conversationId, attachments, trace);
      case SetConversationAttachmentStatus(
        :final conversationId,
        :final statusCode,
      ):
        _setAttachmentStatus(conversationId, statusCode, trace: trace);
      case ClearConversationAttachments(:final conversationId):
        final attachments = _controller.conversationPresentationSignals
            .composerAttachmentsFor(conversationId);
        _controller.conversationPresentationSignals.replaceComposerAttachments(
          conversationId,
          const [],
        );
        _controller.conversationPresentationSignals
            .replaceComposerAttachmentStatus(conversationId, '');
        _releaseAttachments(attachments);
        _projection.cacheAttachmentBytes(
          const <String, List<int>>{},
          trace: trace,
        );
        _projection.publishLocalChange(trace: trace);
      case SelectConversationModel(:final model):
        _controller.selectConversationModel(model);
        _projection.publishLocalChange(trace: trace);
      case SelectConversationReasoningEffort(:final effort):
        _controller.selectConversationReasoningEffort(effort);
        _projection.publishLocalChange(trace: trace);
      case SelectConversationLicoProfile(:final profile):
        _controller.selectConversationLicoProfile(profile);
        _projection.publishLocalChange(trace: trace);
      case RetryConversationPermission(:final remember):
        _runResult(
          () => _controller.retryDeniedConversationTurn(remember: remember),
          trace,
          stage: 'permission-retry',
        );
      case DismissConversationPermission():
        _controller.dismissDeniedConversationTurn();
        _projection.publishLocalChange(trace: trace);
      case AuthorizeConversationRuntime():
        _run(
          _controller.authorizeSelectedConversationRuntime,
          trace,
          stage: 'runtime-authorize',
        );
      case CopyConversationFailure(:final content):
        _run(
          () => _controller.clientClipboardService.writeText(content),
          trace,
          stage: 'failure-copy',
        );
      case ReplaceConversationAttachments(
        :final conversationId,
        :final attachments,
        :final statusCode,
      ):
        _controller.conversationPresentationSignals.replaceComposerAttachments(
          conversationId,
          attachments,
        );
        _controller.conversationPresentationSignals
            .replaceComposerAttachmentStatus(conversationId, statusCode);
        _projection.publishLocalChange(trace: trace);
      case RemoveConversationAttachment(
        :final conversationId,
        :final attachmentId,
      ):
        final current = _controller.conversationPresentationSignals
            .composerAttachmentsFor(conversationId);
        final removed = current
            .where((attachment) => attachment.id == attachmentId)
            .toList(growable: false);
        _controller.conversationPresentationSignals.replaceComposerAttachments(
          conversationId,
          current
              .where((attachment) => attachment.id != attachmentId)
              .toList(growable: false),
        );
        unawaited(
          _controller.conversationAttachmentRelease.releaseAttachments(removed),
        );
        _projection.publishLocalChange(trace: trace);
      case RetryConversationDispatch(
        :final conversationId,
        :final membershipId,
      ):
        if (_controller.clientConversationController.selectedConversationId ==
            conversationId) {
          _runResult(
            () => _controller.clientConversationController.retryMessage(
              membershipId,
            ),
            trace,
            stage: 'canonical-retry',
          );
        } else {
          _runResult(
            () => _controller.retryDeniedConversationTurn(),
            trace,
            stage: 'native-retry',
          );
        }
      case DismissConversationFailure():
        _controller.dismissDeniedConversationTurn();
        _projection.publishLocalChange(trace: trace);
      case InterruptConversationTurn(
        :final conversationId,
        :final membershipId,
      ):
        if (_controller.clientConversationController.selectedConversationId ==
            conversationId) {
          _run(
            () => _projection.cancelGroupTurn(membershipId),
            trace,
            stage: 'canonical-cancel',
          );
        } else {
          _run(
            _controller.cancelActiveConversationTurn,
            trace,
            stage: 'native-cancel',
          );
        }
      case RetryCanonicalConversationMessage(:final eventId):
        _runResult(
          () => _controller.clientConversationController.retryMessage(eventId),
          trace,
          stage: 'canonical-retry',
        );
      case DeleteCanonicalConversationMessage(:final eventId):
        _runResult(
          () => _controller.clientConversationController.deleteMessage(eventId),
          trace,
          stage: 'canonical-delete',
        );
      case RefreshCanonicalAssistantThread():
        _runResult(
          _controller
              .clientConversationController
              .refreshSelectedAssistantThread,
          trace,
          stage: 'assistant-refresh',
        );
      case RefreshCanonicalAssistantProfile():
        _run(
          _projection.refreshCanonicalAssistantProfile,
          trace,
          stage: 'assistant-profile-refresh',
        );
      case SurfaceConversationFailure(:final stage, :final reasonCode):
        _controller.clientConversationController.surfaceFailure(
          stage,
          reasonCode,
        );
        _projection.publishLocalChange(trace: trace);
      case EnsureCanonicalAgentMembership(:final agentId, :final displayName):
        _runResult(
          () => _controller.clientConversationController
              .ensureSelectedAgentMembership(
                agentId: agentId,
                displayName: displayName,
              ),
          trace,
          stage: 'member-add',
        );
      case SetCanonicalAssistantMembership(:final membershipId):
        _runResult(
          () => _controller.clientConversationController
              .setSelectedAssistantMembership(membershipId),
          trace,
          stage: 'assistant-set',
        );
      case SetCanonicalStrategyRevision(:final revision):
        _runResult(
          () => _controller.clientConversationController
              .setSelectedStrategyRevision(revision),
          trace,
          stage: 'strategy-set',
          onSuccess: () {
            unawaited(_projection.refreshCanonicalAssistantProfile());
            unawaited(_projection.refreshCanonicalStrategyProjection());
          },
        );
      case SetCanonicalConversationPinned(:final conversationId, :final pinned):
        _run(
          () => _controller.clientConversationController.setPinned(
            conversationId,
            pinned,
          ),
          trace,
          stage: 'canonical-pin',
        );
      case SetCanonicalConversationSurfaceAttached(:final attached):
        attached
            ? _controller.providerQuotaController.acquirePollingOwner(this)
            : _controller.providerQuotaController.releasePollingOwner(this);
      case SetConversationTabActive(:final active):
        if (active) {
          _controller.acknowledgeConversationTabWorkFinished(
            _controller.selectedConversationAgentId,
          );
        }
      case ArchiveConversation(:final conversationId):
        _runResult(
          () => _controller.clientConversationController.archiveConversation(
            conversationId,
          ),
          trace,
          stage: 'archive',
        );
      case RestoreConversation(:final conversationId):
        _runResult(
          () => _controller.clientConversationController.restoreArchived(
            conversationId,
          ),
          trace,
          stage: 'restore',
        );
      case BackupAllNativeConversations(
        :final sourceAgentId,
        :final destination,
      ):
        _runArchive(
          () => _controller.archiveAllConversations(
            sourceAgentId: sourceAgentId,
            path: destination,
          ),
          trace,
        );
      case BackupNativeConversationsByExactKeyword(
        :final query,
        :final sourceAgentId,
        :final destination,
      ):
        _controller.archiveQueryDraft = query;
        _runArchive(
          () => _controller.archiveConversationExactKeyword(
            query: query,
            sourceAgentId: sourceAgentId,
            path: destination,
          ),
          trace,
        );
    }
  }

  void _runPasteAttachment(String conversationId, TraceContext? trace) {
    unawaited(
      () async {
        final result = await _controller.clientClipboardService
            .readImageAttachment();
        if (!result.consumed) return;
        final attachment = result.attachment;
        if (!result.succeeded || attachment == null) {
          _setAttachmentStatus(
            conversationId,
            result.failureCode,
            trace: trace,
          );
          return;
        }
        await _stageAttachments(conversationId, [attachment], trace);
      }().catchError((Object _) {
        _setAttachmentStatus(
          conversationId,
          conversationAttachmentStatusFailed,
          trace: trace,
        );
      }),
    );
  }

  void _runStageAttachments(
    String conversationId,
    List<ConversationAttachment> attachments,
    TraceContext? trace,
  ) {
    unawaited(
      _stageAttachments(conversationId, attachments, trace).catchError((
        Object _,
      ) {
        _setAttachmentStatus(
          conversationId,
          conversationAttachmentStatusFailed,
          trace: trace,
        );
      }),
    );
  }

  Future<void> _stageAttachments(
    String conversationId,
    List<ConversationAttachment> additions,
    TraceContext? trace,
  ) async {
    final current = _controller.conversationPresentationSignals
        .composerAttachmentsFor(conversationId);
    Future<void> reject(String code) async {
      await _controller.conversationAttachmentRelease.releaseAttachments(
        additions,
      );
      _setAttachmentStatus(conversationId, code, trace: trace);
    }

    if (current.length + additions.length > maxConversationImageAttachments) {
      await reject(conversationAttachmentStatusLimit);
      return;
    }
    var totalBytes = 0;
    final bytesById = <String, List<int>>{};
    for (final attachment in [...current, ...additions]) {
      final read = await _controller.conversationImageByteReader.read(
        localPath: attachment.path,
        mediaType: attachment.mediaType,
      );
      if (!read.succeeded) {
        await reject(read.failureCode);
        return;
      }
      final bytes = read.bytes!;
      totalBytes += bytes.length;
      bytesById[attachment.id] = bytes;
      if (totalBytes > maxConversationImageBytesTotal) {
        await reject(conversationAttachmentFailureSizeLimit);
        return;
      }
    }
    _controller.conversationPresentationSignals.replaceComposerAttachments(
      conversationId,
      [...current, ...additions],
    );
    _projection.cacheAttachmentBytes(bytesById, trace: trace);
    _setAttachmentStatus(conversationId, '', trace: trace);
  }

  void _setAttachmentStatus(
    String conversationId,
    String code, {
    TraceContext? trace,
  }) {
    _controller.conversationPresentationSignals.replaceComposerAttachmentStatus(
      conversationId,
      code,
    );
    _projection.publishLocalChange(trace: trace);
  }

  void _runArchive(Future<void> Function() action, TraceContext? trace) {
    _projection.publishLocalChange(trace: trace);
    unawaited(
      action()
          .catchError((Object _) {
            _reject(trace, 'native-archive');
          })
          .whenComplete(() {
            _projection.publishLocalChange(trace: trace);
          }),
    );
  }

  void _post(
    String conversationId,
    String content,
    bool dispatchCanonical,
    TraceContext? trace,
  ) {
    final attachments = _controller.conversationPresentationSignals
        .composerAttachmentsFor(conversationId);
    final canonicalId =
        _controller.clientConversationController.selectedConversationId;
    if (canonicalId.isNotEmpty && conversationId == 'group:$canonicalId') {
      _runResult(
        () => _controller.clientConversationController.postMessage(
          content,
          dispatch: dispatchCanonical,
          attachments: attachments,
        ),
        trace,
        stage: 'canonical-send',
        onSuccess: () => _clearComposer(conversationId, trace: trace),
      );
      return;
    }
    _runResult(
      () => _controller.sendConversationMessage(
        content,
        attachmentOverride: attachments,
      ),
      trace,
      stage: 'native-send',
    );
  }

  void _clearComposer(String scopeKey, {TraceContext? trace}) {
    final attachments = _controller.conversationPresentationSignals
        .composerAttachmentsFor(scopeKey);
    _controller.conversationPresentationSignals.replaceComposerDraft(
      scopeKey,
      '',
    );
    _controller.conversationPresentationSignals.replaceComposerAttachments(
      scopeKey,
      const <ConversationAttachment>[],
    );
    _controller.conversationPresentationSignals.replaceComposerAttachmentStatus(
      scopeKey,
      '',
    );
    _releaseAttachments(attachments);
    _projection.cacheAttachmentBytes(const <String, List<int>>{}, trace: trace);
  }

  void _releaseAttachments(List<ConversationAttachment> attachments) {
    if (attachments.isEmpty) return;
    unawaited(() async {
      try {
        await _controller.conversationAttachmentRelease.releaseAttachments(
          attachments,
        );
      } on Object {
        // Staging cleanup must not turn a committed send or an explicit clear
        // into a failed Conversation action. Semantic state is already clear.
      }
    }());
  }

  void _run(
    Future<void> Function() action,
    TraceContext? trace, {
    required String stage,
  }) {
    unawaited(() async {
      try {
        final pending = action();
        _projection.publishLocalChange(trace: trace);
        await pending;
        _projection.publishLocalChange(trace: trace);
      } on Object {
        _reject(trace, stage);
      }
    }());
  }

  void _runResult(
    Future<bool> Function() action,
    TraceContext? trace, {
    required String stage,
    void Function()? onSuccess,
  }) {
    unawaited(() async {
      try {
        final pending = action();
        _projection.publishLocalChange(trace: trace);
        final ok = await pending;
        if (ok) {
          onSuccess?.call();
          _projection.publishLocalChange(trace: trace);
        } else {
          _reject(trace, stage);
        }
      } on Object {
        _reject(trace, stage);
      }
    }());
  }

  void _reject(TraceContext? trace, String stage) {
    _effects.add(
      ConversationActionRejected(
        conversationId: _projection.projection.current.conversationId,
        stage: stage,
        reasonCode: 'conversation_action_failed',
        trace: trace,
      ),
    );
  }
}
