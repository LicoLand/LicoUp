import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_conversation_overlay_glass.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

import 'conversation_execution_models.dart';
import 'execution_document.dart';
import 'execution_viewer_body.dart';
import 'execution_viewer_header.dart';

export 'conversation_execution_models.dart';

/// Opens an endpoint-local, read-only view. The caller owns [source] and keeps
/// it alive until this future completes. Closing restores the trigger's focus.
Future<void> showConversationExecutionViewer({
  required BuildContext context,
  required ValueListenable<ConversationExecutionSnapshot> source,
  required Widget agentIcon,
  required String agentName,
  required String conversationTitle,
  required Future<void> Function(String) onCopyText,
  FocusNode? returnFocusNode,
}) async {
  final triggerFocus = returnFocusNode ?? FocusManager.instance.primaryFocus;
  await showDialog<void>(
    context: context,
    useRootNavigator: false,
    requestFocus: true,
    animationStyle: AnimationStyle(
      duration: context.motion(LicoMotion.short),
      reverseDuration: context.motion(LicoMotion.micro),
    ),
    builder: (dialogContext) => Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1180, maxHeight: 900),
        child: ConversationExecutionViewer(
          source: source,
          agentIcon: agentIcon,
          agentName: agentName,
          conversationTitle: conversationTitle,
          onCopyText: onCopyText,
          onClose: () => Navigator.of(dialogContext).pop(),
        ),
      ),
    ),
  );
  if (triggerFocus?.context != null && triggerFocus!.canRequestFocus) {
    triggerFocus.requestFocus();
  }
}

class ConversationExecutionViewer extends StatefulWidget {
  const ConversationExecutionViewer({
    super.key,
    required this.source,
    required this.agentIcon,
    required this.agentName,
    required this.conversationTitle,
    required this.onCopyText,
    required this.onClose,
    this.layoutYield,
  });

  final ValueListenable<ConversationExecutionSnapshot> source;
  final Widget agentIcon;
  final String agentName;
  final String conversationTitle;
  final Future<void> Function(String) onCopyText;
  final VoidCallback onClose;

  @visibleForTesting
  final Future<void> Function()? layoutYield;

  @override
  State<ConversationExecutionViewer> createState() =>
      _ConversationExecutionViewerState();
}

class _ConversationExecutionViewerState
    extends State<ConversationExecutionViewer> {
  final _scroll = ScrollController(keepScrollOffset: false);
  final _search = TextEditingController();
  final _searchFocus = FocusNode();
  late ConversationExecutionSnapshot _snapshot;
  ExecutionDocument? _document;
  ExecutionDocument? _requestedDocument;
  ExecutionDocument? _activeDocument;
  ExecutionDocumentAnchor? _restoreAnchor;
  bool _layoutRunning = false;
  int _layoutGeneration = 0;
  bool _pendingSearchJump = false;
  List<ExecutionSearchMatch> _matches = const [];
  String _submittedQuery = '';
  String _selectedText = '';
  int _matchIndex = -1;
  bool _followingLatest = true;
  bool _pendingLatest = true;
  bool _nearLatest = true;

  @override
  void initState() {
    super.initState();
    _snapshot = widget.source.value;
    widget.source.addListener(_sourceChanged);
    _scroll.addListener(_scrollChanged);
    _searchFocus.addListener(_searchFocusChanged);
  }

  @override
  void didUpdateWidget(covariant ConversationExecutionViewer oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) {
      oldWidget.source.removeListener(_sourceChanged);
      widget.source.addListener(_sourceChanged);
      _sourceChanged();
    }
  }

  void _sourceChanged() {
    setState(() {
      final next = widget.source.value;
      final active = _activeDocument ?? _requestedDocument;
      if (active == null ||
          !executionRecordsExtend(active.records, next.records)) {
        _layoutGeneration += 1;
        _requestedDocument = null;
      }
      _snapshot = next;
      if (_submittedQuery.isNotEmpty) {
        _matches = searchExecutionRecords(_snapshot.records, _submittedQuery);
        _matchIndex = _matches.isEmpty
            ? -1
            : math.min(math.max(0, _matchIndex), _matches.length - 1);
      }
      if (_followingLatest && !_searchFocus.hasFocus) _pendingLatest = true;
    });
  }

  void _searchFocusChanged() {
    if (_searchFocus.hasFocus) {
      setState(() {
        _followingLatest = false;
        _pendingLatest = false;
      });
    }
  }

  void _scrollChanged() {
    if (!_scroll.hasClients) return;
    final near = _scroll.position.extentAfter < 24;
    if (near != _nearLatest) setState(() => _nearLatest = near);
  }

  bool _onScroll(ScrollNotification notification) {
    if (notification.depth == 0 &&
        notification is UserScrollNotification &&
        notification.direction != ScrollDirection.idle) {
      setState(() {
        _pendingLatest = false;
        _followingLatest = false;
      });
    }
    return false;
  }

  void _queueLatest() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_pendingLatest || !_scroll.hasClients) return;
      _pendingLatest = false;
      _scroll.jumpTo(_scroll.position.maxScrollExtent);
    });
  }

  void _backToLatest() {
    _search.clear();
    _searchFocus.unfocus();
    setState(() {
      _submittedQuery = '';
      _matches = const [];
      _matchIndex = -1;
      _pendingSearchJump = false;
      _restoreAnchor = null;
      _followingLatest = true;
      _pendingLatest = true;
    });
  }

  void _searchChanged(String value) {
    setState(() {
      _submittedQuery = '';
      _matches = const [];
      _matchIndex = -1;
      _pendingSearchJump = false;
      if (value.isNotEmpty) {
        _followingLatest = false;
        _pendingLatest = false;
      }
    });
  }

  void _findMatch({bool backwards = false}) {
    final query = _search.text;
    if (query.isEmpty) return;
    setState(() {
      _followingLatest = false;
      _pendingLatest = false;
      if (_submittedQuery != query) {
        _submittedQuery = query;
        _matches = searchExecutionRecords(_snapshot.records, query);
        _matchIndex = backwards ? _matches.length - 1 : 0;
      } else if (_matches.isNotEmpty) {
        _matchIndex = (_matchIndex + (backwards ? -1 : 1)) % _matches.length;
      }
      if (_matches.isEmpty) _matchIndex = -1;
      _pendingSearchJump = _matchIndex >= 0;
    });
    _queueDocumentPosition();
  }

  void _requestDocumentLayout(ExecutionDocument request) {
    final pending = _requestedDocument;
    if (pending != null &&
        pending.records == request.records &&
        pending.sameLayoutAs(request)) {
      return;
    }
    _requestedDocument = request;
    final active = _activeDocument;
    if (active == null ||
        !active.sameLayoutAs(request) ||
        !executionRecordsExtend(active.records, request.records)) {
      _layoutGeneration += 1;
    }
    if (_layoutRunning) return;
    _layoutRunning = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_layoutDocuments());
    });
  }

  Future<void> _layoutDocuments() async {
    while (mounted && _requestedDocument != null) {
      final request = _requestedDocument!;
      _activeDocument = request;
      final generation = _layoutGeneration;
      final complete = await request.prepare(
        previous: _document,
        isCurrent: () => mounted && generation == _layoutGeneration,
        yieldToUi: widget.layoutYield,
      );
      if (!mounted) return;
      _activeDocument = null;
      if (!complete || generation != _layoutGeneration) continue;
      setState(() {
        _document = request;
        if (identical(_requestedDocument, request)) _requestedDocument = null;
        _pendingLatest = _followingLatest && !_searchFocus.hasFocus;
      });
      _queueDocumentPosition();
    }
    _layoutRunning = false;
  }

  void _queueDocumentPosition() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_scroll.hasClients) return;
      final document = _document;
      if (document == null || document.records != _snapshot.records) return;
      double? destination;
      if (_pendingSearchJump && _matchIndex >= 0) {
        destination = document.offsetForMatch(_matches[_matchIndex]) - 20;
        _pendingSearchJump = false;
        _restoreAnchor = null;
      } else if (!_followingLatest && _restoreAnchor != null) {
        destination = document.offsetForAnchor(_restoreAnchor!);
        _restoreAnchor = null;
      }
      if (destination == null) return;
      _scroll.jumpTo(destination.clamp(0.0, _scroll.position.maxScrollExtent));
    });
  }

  void _preserveReadPosition() {
    final document = _document;
    if (document != null &&
        _scroll.hasClients &&
        !_followingLatest &&
        _restoreAnchor == null) {
      _restoreAnchor = document.anchorAtOffset(_scroll.offset);
    }
  }

  void _selectionChanged(String text) {
    _selectedText = text;
    if (text.isNotEmpty) {
      _followingLatest = false;
      _pendingLatest = false;
    }
  }

  void _copySelection() {
    if (_selectedText.isNotEmpty) {
      unawaited(widget.onCopyText(_selectedText));
    }
  }

  @override
  void dispose() {
    _layoutGeneration += 1;
    _requestedDocument = null;
    widget.source.removeListener(_sourceChanged);
    _scroll.dispose();
    _search.dispose();
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    if (_pendingLatest) _queueLatest();
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): widget.onClose,
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true):
            _searchFocus.requestFocus,
        const SingleActivator(LogicalKeyboardKey.keyF, control: true):
            _searchFocus.requestFocus,
      },
      child: Focus(
        autofocus: true,
        child: ConversationExecutionSurface(
          child: Material(
            color: colors.surface.withAlpha(colors.isDark ? 230 : 245),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ExecutionViewerHeader(
                  agentIcon: widget.agentIcon,
                  agentName: widget.agentName,
                  conversationTitle: widget.conversationTitle,
                  onClose: widget.onClose,
                  searchController: _search,
                  searchFocus: _searchFocus,
                  onSearchChanged: _searchChanged,
                  onNextMatch: _findMatch,
                  onPreviousMatch: () => _findMatch(backwards: true),
                  hasSubmittedQuery: _submittedQuery.isNotEmpty,
                  matchCount: _matches.length,
                  matchIndex: _matchIndex,
                ),
                Divider(height: 1, thickness: 1, color: colors.line),
                Expanded(
                  child: ExecutionViewerBody(
                    snapshot: _snapshot,
                    document: _document,
                    requestedDocument: _requestedDocument,
                    scrollController: _scroll,
                    matches: _matches,
                    matchIndex: _matchIndex,
                    showLatest: !_nearLatest || !_followingLatest,
                    onDocumentRequested: _requestDocumentLayout,
                    onPreparing: _preserveReadPosition,
                    onScroll: _onScroll,
                    onBackToLatest: _backToLatest,
                    onCopyText: widget.onCopyText,
                    onSelectedTextChanged: _selectionChanged,
                    onCopySelection: _copySelection,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One shared messaging-glass rim around the execution surface.
class ConversationExecutionSurface extends StatelessWidget {
  const ConversationExecutionSurface({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => MessagingConversationOverlayGlass(
    borderRadius: BorderRadius.circular(LicoRadius.card),
    child: child,
  );
}
