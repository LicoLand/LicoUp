import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:presentation_contract/presentation_contract.dart';

import 'package:licoup/src/frontend/shared/ui/message_markdown_block_view.dart';
import 'package:licoup/src/frontend/shared/ui/message_markdown_models.dart';
import 'package:licoup/src/frontend/shared/ui/message_markdown_style.dart';
import 'package:licoup/src/presentation/conversation/conversation_markdown_port.dart';

export 'package:licoup/src/frontend/shared/ui/message_markdown_models.dart';
export 'package:licoup/src/frontend/shared/ui/message_markdown_style.dart';

/// Composer for prepared message markdown blocks.
///
/// The widget renders the [PreparedValue] the presentation runtime installed
/// for one message body. It never parses, normalizes, or scans the body text:
/// the runtime's engine decomposes and parses the text in a worker isolate, and
/// this widget only lays out the prepared blocks it receives. A restyle or a
/// parent rebuild therefore repaints from the same prepared value and cannot
/// invalidate preparation.
///
/// The complete original text stays in [data] for full-body viewing, selection,
/// and copy. While a revision is still being prepared - or while a view runs
/// outside a presentation container, such as an isolated widget test - the
/// widget renders that text as calm, unparsed body text instead of parsing it
/// on the rendering path.
///
/// Streaming uses the runtime's own split: blocks the prepared value already
/// froze render with final styling, and the mutable tail renders as the quiet
/// in-progress presentation. An unclosed code fence keeps its frame from the
/// opening fence, exactly as the finalized rendering shows it.
///
/// A withdrawal is not a loading state. When the application withdraws
/// authority over a body the content stops being visible and a repeated read of
/// the same text never brings it back; only a changed narrow input opens a
/// fresh incarnation. A bounded cache retire is different: its input text is
/// still the conversation's own read, so the view may show the calm local
/// loading presentation while a later input prepares it again.
final class MessageMarkdown extends StatefulWidget {
  const MessageMarkdown({
    super.key,
    required this.data,
    required this.foreground,
    required this.accent,
    required this.codeBackground,
    required this.blockBackground,
    required this.borderColor,
    this.renderStyle = const MessageMarkdownStyle(),
    this.isStreaming = false,
    this.identity = '',
  });

  /// The complete original body text of this message.
  final String data;
  final Color foreground;
  final Color accent;
  final Color codeBackground;
  final Color blockBackground;
  final Color borderColor;
  final MessageMarkdownStyle renderStyle;

  /// Whether [data] is a partially written streamed reply. Streaming mode
  /// renders the frozen block prefix with final styling under stable keys and
  /// the still-growing tail in a quiet in-progress presentation; the default
  /// (false) is the exact finalized rendering.
  final bool isStreaming;

  /// Stable identity of the message body this view renders.
  ///
  /// The prepared pipeline keys one source per identity, so the same message
  /// keeps its prepared value across rebuilds, scrolling, and reordering. A
  /// caller that leaves this empty gets an identity for this widget instance
  /// only: the body is still prepared off-thread, but a new instance prepares
  /// it again. Callers that know the projected message identity should pass it
  /// so a message re-entering the viewport reuses its prepared value.
  final String identity;

  @override
  State<MessageMarkdown> createState() => _MessageMarkdownState();
}

class _MessageMarkdownState extends State<MessageMarkdown> {
  static int _instances = 0;

  late final String _fallbackIdentity =
      'message-markdown-instance-${_instances++}';
  ConversationMarkdownPort? _preparation;
  bool _resolvedPreparation = false;
  void Function()? _releaseWatch;
  String _identity = '';
  String? _publishedText;
  SourcePosition? _position;
  ConversationMarkdownBodyState? _state;

  String get _messageIdentity {
    final declared = widget.identity.trim();
    if (declared.isNotEmpty) return declared;
    final key = widget.key;
    if (key is ValueKey<String> && key.value.trim().isNotEmpty) {
      return key.value.trim();
    }
    return _fallbackIdentity;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _resolvePreparation();
    _syncBody();
  }

  @override
  void didUpdateWidget(covariant MessageMarkdown oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data != widget.data ||
        oldWidget.identity != widget.identity ||
        oldWidget.key != widget.key) {
      _syncBody();
    }
  }

  @override
  void dispose() {
    _releaseWatch?.call();
    _releaseWatch = null;
    super.dispose();
  }

  /// Resolves the container-scoped pipeline once per mounted view.
  ///
  /// A view outside a [ProviderScope] - an isolated widget test or a preview -
  /// keeps rendering its own text and never parses on the rendering path.
  void _resolvePreparation() {
    if (_resolvedPreparation) return;
    _resolvedPreparation = true;
    try {
      final container = ProviderScope.containerOf(context, listen: false);
      _preparation = container.read(conversationMarkdownPortProvider);
    } on Object {
      _preparation = null;
    }
  }

  /// Publishes this view's narrow input and follows its own prepared state.
  ///
  /// The same narrow input never re-enters preparation by itself: a rebuild or
  /// a restyle of the same text is not a new read, so a withdrawn body stays
  /// withdrawn until the text or the identity actually changes.
  void _syncBody() {
    final preparation = _preparation;
    if (preparation == null) return;
    final identity = _messageIdentity;
    if (identity != _identity) {
      _releaseWatch?.call();
      _releaseWatch = null;
      _identity = identity;
      _publishedText = null;
      _position = null;
      _state = null;
      _releaseWatch = preparation.watch(identity, _onState);
    }
    final text = widget.data;
    if (_publishedText == text) {
      _state = preparation.stateFor(identity);
      return;
    }
    _publishedText = text;
    _position = preparation.publish(identity: identity, text: text);
    _state = preparation.stateFor(identity);
  }

  void _onState(ConversationMarkdownBodyState state) {
    if (!mounted) return;
    if (_sameState(_state, state)) return;
    setState(() => _state = state);
  }

  bool _sameState(
    ConversationMarkdownBodyState? left,
    ConversationMarkdownBodyState right,
  ) {
    if (left == null) return false;
    if (left.runtimeType != right.runtimeType) return false;
    if (left is ConversationMarkdownInstalled &&
        right is ConversationMarkdownInstalled) {
      return identical(left.value, right.value);
    }
    if (left is ConversationMarkdownWithdrawn &&
        right is ConversationMarkdownWithdrawn) {
      return left.reason == right.reason;
    }
    return true;
  }

  /// The installed value that matches the text this view currently holds.
  PreparedValue<MessageMarkdownBlock>? get _visiblePrepared {
    final state = _state;
    if (state is! ConversationMarkdownInstalled) return null;
    final value = state.value;
    if (_position == null || value.position != _position) return null;
    return value;
  }

  TextStyle _baseStyle(BuildContext context) =>
      DefaultTextStyle.of(context).style.copyWith(
        color: widget.foreground,
        height: widget.renderStyle.bodyLineHeight,
        fontSize: widget.renderStyle.bodyFontSize,
        letterSpacing: 0,
      );

  @override
  Widget build(BuildContext context) {
    final baseStyle = _baseStyle(context);
    if (widget.data.trim().isEmpty) return Text('', style: baseStyle);
    final state = _state;
    if (state is ConversationMarkdownWithdrawn) {
      // An authority withdrawal hides the content outright: neither the
      // prepared value nor the text this view still holds may resurrect it.
      // A cache retire only drops the prepared value, so its input text keeps
      // the legitimate local-loading presentation.
      return state.reason == ConversationMarkdownWithdrawal.retired
          ? _buildUnprepared(baseStyle)
          : const SizedBox.shrink();
    }
    final prepared = _visiblePrepared;
    if (prepared == null || prepared.blocks.isEmpty) {
      return _buildUnprepared(baseStyle);
    }
    return _buildPrepared(prepared, baseStyle);
  }

  /// The calm, unparsed presentation of the text this view already holds.
  ///
  /// This is a local loading state for a revision that is not visible yet -
  /// no preparation configured, a preparation in flight, an installed value
  /// from another revision, or a cache-retired body. It is not a second
  /// rendering route and never a fallback for a withdrawn value: nothing here
  /// reads Markdown structure.
  Widget _buildUnprepared(TextStyle baseStyle) {
    return Text(widget.data, style: baseStyle);
  }

  Widget _buildPrepared(
    PreparedValue<MessageMarkdownBlock> prepared,
    TextStyle baseStyle,
  ) {
    final frozen = <BlockId>{
      for (final block in prepared.immutablePrefix) block.id,
    };
    final children = <Widget>[];
    for (var index = 0; index < prepared.blocks.length; index++) {
      final block = prepared.blocks[index];
      if (children.isNotEmpty) {
        children.add(SizedBox(height: widget.renderStyle.blockSpacing));
      }
      final isFrozen = !widget.isStreaming || frozen.contains(block.id);
      children.add(
        isFrozen
            ? MessageMarkdownBlockView(
                // Anchored by the runtime's own block identity: a completed
                // block keeps its element while the stream grows behind it,
                // and a replaced source issues new identities.
                key: ValueKey<String>(
                  'message-markdown-block-${block.id.value}',
                ),
                block: block.value,
                baseStyle: baseStyle,
                foreground: widget.foreground,
                accent: widget.accent,
                codeBackground: widget.codeBackground,
                blockBackground: widget.blockBackground,
                borderColor: widget.borderColor,
                renderStyle: widget.renderStyle,
              )
            : _buildStreamingTail(block, baseStyle),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
  }

  /// The still-growing tail in the calm base presentation.
  ///
  /// An unclosed code fence is the one exception: its frame renders from the
  /// opening fence and stays the same frame once the closing fence arrives.
  /// Other tails consume the worker's settled-prefix/remainder split directly;
  /// the view neither scans source text nor invents its streaming grammar.
  Widget _buildStreamingTail(
    PreparedBlock<MessageMarkdownBlock> block,
    TextStyle baseStyle,
  ) {
    if (block.value.type == MessageMarkdownBlockType.code) {
      return MessageMarkdownBlockView(
        key: ValueKey<String>('message-markdown-block-${block.id.value}'),
        block: block.value,
        baseStyle: baseStyle,
        foreground: widget.foreground,
        accent: widget.accent,
        codeBackground: widget.codeBackground,
        blockBackground: widget.blockBackground,
        borderColor: widget.borderColor,
        renderStyle: widget.renderStyle,
      );
    }
    return MessageMarkdownStreamingBlockView(
      key: ValueKey<String>('message-markdown-tail-${block.id.value}'),
      block: block.value,
      baseStyle: baseStyle,
      foreground: widget.foreground,
      accent: widget.accent,
      codeBackground: widget.codeBackground,
      blockBackground: widget.blockBackground,
      borderColor: widget.borderColor,
      renderStyle: widget.renderStyle,
    );
  }
}
