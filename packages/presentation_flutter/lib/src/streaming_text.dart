import 'package:flutter/material.dart';
import 'package:presentation_contract/presentation_contract.dart';
import 'package:presentation_runtime/presentation_runtime.dart'
    show
        MessageMarkdownBlock,
        MessageMarkdownBlockType,
        MessageMarkdownInline,
        MessageMarkdownInlineRun;

/// Splits already prepared display text into consecutive pieces of at most
/// [targetLength] UTF-16 code units.
///
/// The result is lossless: `partitionStreamingText(text).join()` equals `text`,
/// so slicing never truncates or rewrites the original. Boundaries prefer line
/// ends, and a single over-long line is cut at extended grapheme cluster
/// boundaries, so no character, surrogate pair, or combining sequence is split
/// across two pieces. This is a layout aid for long blocks; call it while
/// assembling a presentation value, never from a widget build.
List<String> partitionStreamingText(String text, {int targetLength = 2048}) {
  if (targetLength < 1) {
    throw ArgumentError.value(
      targetLength,
      'targetLength',
      'a slice must hold at least one code unit',
    );
  }
  if (text.isEmpty) return const <String>[];

  final slices = <String>[];
  final buffer = StringBuffer();
  var buffered = 0;

  void flush() {
    if (buffered == 0) return;
    slices.add(buffer.toString());
    buffer.clear();
    buffered = 0;
  }

  var start = 0;
  while (start < text.length) {
    var end = text.indexOf('\n', start);
    end = end < 0 ? text.length : end + 1;
    final line = text.substring(start, end);
    start = end;

    if (buffered + line.length <= targetLength) {
      buffer.write(line);
      buffered += line.length;
      continue;
    }
    flush();
    if (line.length <= targetLength) {
      buffer.write(line);
      buffered = line.length;
      continue;
    }

    // One line longer than the target: cut it on grapheme clusters.
    var chunkStart = 0;
    var chunkLength = 0;
    for (final cluster in line.characters) {
      if (chunkLength > 0 && chunkLength + cluster.length > targetLength) {
        slices.add(line.substring(chunkStart, chunkStart + chunkLength));
        chunkStart += chunkLength;
        chunkLength = 0;
      }
      chunkLength += cluster.length;
    }
    buffer.write(line.substring(chunkStart));
    buffered = chunkLength;
  }
  flush();
  return List<String>.unmodifiable(slices);
}

/// Immutable, renderer-ready text presenter for one prepared value.
///
/// It receives the installed [PreparedValue] and renders the prepared blocks it
/// already contains. It never parses, normalizes, or re-reads source text: a
/// block that the preparation sealed is rendered from its prepared payload, and
/// a restyle never invalidates that work. Long blocks are laid out as bounded
/// slices ([partitionStreamingText]) instead of one unbounded text object, while
/// the original prepared text stays complete for selection, copy, and
/// accessibility.
///
/// Anchors are per slice and stable while a source epoch keeps treating a block
/// as the same block, so a growing mutable tail does not renumber or recreate
/// the rows above it. A replaced source opens a new epoch and therefore new
/// anchors, which is what keeps an old anchor from addressing new content.
///
/// The widget owns no source, provider, controller, or action: a host passes
/// prepared values in and receives copy requests back through [onCopy].
class StreamingText extends StatefulWidget {
  const StreamingText({
    super.key,
    required this.prepared,
    this.style,
    this.codeStyle,
    this.quoteStyle,
    this.warningStyle,
    this.headingStyle,
    this.markerStyle,
    this.tableHeaderStyle,
    this.onCopy,
    this.controller,
    this.padding = EdgeInsets.zero,
    this.physics,
    this.shrinkWrap = true,
    this.blockSpacing = 8.0,
    this.selectable = true,
    this.targetSliceLength = 2048,
  }) : assert(targetSliceLength > 0, 'targetSliceLength must be positive');

  /// The installed prepared value to render.
  final PreparedValue<MessageMarkdownBlock> prepared;

  /// Base text style for ordinary blocks.
  final TextStyle? style;

  /// Style for fenced code blocks.
  final TextStyle? codeStyle;

  /// Style for blockquotes.
  final TextStyle? quoteStyle;

  /// Style for runtime warning blocks.
  final TextStyle? warningStyle;

  /// Base style for headings; the level scales its font size.
  final TextStyle? headingStyle;

  /// Style for list markers.
  final TextStyle? markerStyle;

  /// Style for the first table row.
  final TextStyle? tableHeaderStyle;

  /// Host action that copies the full original text, including the parts that
  /// are outside the viewport. It is exposed as the accessibility copy action
  /// and, when [selectable] is false, also on double tap.
  final VoidCallback? onCopy;

  /// Controller for the bounded presentation, when [shrinkWrap] is false.
  final ScrollController? controller;

  /// Padding around the slice list.
  final EdgeInsetsGeometry padding;

  /// Physics of the bounded presentation; ignored while [shrinkWrap] is true.
  final ScrollPhysics? physics;

  /// Whether the presenter sizes itself to its content.
  ///
  /// The default fits a conversation row. A full-body viewer gives the
  /// presenter a bounded height and sets this to false so only visible slices
  /// are built.
  final bool shrinkWrap;

  /// Vertical space between two blocks.
  final double blockSpacing;

  /// Whether displayed text can be selected and copied by the platform.
  final bool selectable;

  /// Largest slice of prepared text laid out as one text object.
  final int targetSliceLength;

  /// Anchor key of one slice of [block].
  ///
  /// The key is stable across content growth inside one epoch and changes when
  /// the source is replaced, so it can be used to scroll to a slice or to
  /// observe which slices are visible.
  static Key anchorKey(SourceBlock block, int sliceIndex) => ValueKey((
    block.text.resource,
    block.text.position.epoch,
    block.id,
    sliceIndex,
  ));

  @override
  State<StreamingText> createState() => _StreamingTextState();
}

sealed class _Unit {
  const _Unit({required this.block});

  final PreparedBlock<MessageMarkdownBlock> block;

  Key get key;
}

final class _TextUnit extends _Unit {
  const _TextUnit({
    required super.block,
    required this.sliceIndex,
    required this.text,
    this.runs,
    this.marker = '',
    this.label = '',
    this.isFirstSlice = false,
    this.isLastSlice = false,
  });

  final int sliceIndex;
  final String text;

  /// Prepared inline display runs of this slice, when the block carries a
  /// prepared inline value. Null means the slice is plain text: the renderer
  /// shows [text] literally and never tokenizes it.
  final List<MessageMarkdownInlineRun>? runs;

  /// Inline marker: a bullet or an ordered list number.
  final String marker;

  /// Block label rendered above the first slice, such as a fence language.
  final String label;

  final bool isFirstSlice;
  final bool isLastSlice;

  @override
  Key get key => StreamingText.anchorKey(block.block, sliceIndex);
}

final class _TableRowUnit extends _Unit {
  const _TableRowUnit({
    required super.block,
    required this.rowIndex,
    required this.cells,
    required this.cellInline,
    required this.isHeader,
  });

  final int rowIndex;

  /// Authored cell text, used literally when no prepared cell value exists.
  final List<String> cells;

  /// Prepared cell values of this row, in the same order as [cells], or null
  /// when the block carries no prepared cell values.
  final List<MessageMarkdownInline>? cellInline;

  final bool isHeader;

  @override
  Key get key => StreamingText.anchorKey(block.block, rowIndex);
}

class _BlockUnits {
  const _BlockUnits(this.block, this.units);

  final PreparedBlock<MessageMarkdownBlock> block;
  final List<_Unit> units;
}

class _StreamingTextState extends State<StreamingText> {
  List<_Unit> _units = const <_Unit>[];
  Map<Key, int> _indexByKey = const <Key, int>{};

  /// Units per block, reused while the prepared block keeps its identity, so a
  /// growing tail does not re-slice the blocks that did not change.
  Map<BlockId, _BlockUnits> _byBlock = const <BlockId, _BlockUnits>{};

  @override
  void initState() {
    super.initState();
    _installUnits();
  }

  @override
  void didUpdateWidget(covariant StreamingText oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Style, padding, and physics are renderer-local: they repaint from the
    // same prepared value and never invalidate preparation. Only a new
    // prepared value changes what the slices are.
    if (!identical(widget.prepared, oldWidget.prepared)) {
      if (widget.prepared.resource != oldWidget.prepared.resource ||
          widget.prepared.position.epoch != oldWidget.prepared.position.epoch) {
        _byBlock = const <BlockId, _BlockUnits>{};
      }
      _installUnits();
    }
  }

  void _installUnits() {
    final units = <_Unit>[];
    final byBlock = <BlockId, _BlockUnits>{};
    for (final block in widget.prepared.blocks) {
      final cached = _byBlock[block.id];
      final entry = cached != null && cached.block == block
          ? cached
          : _buildUnits(block);
      byBlock[block.id] = entry;
      units.addAll(entry.units);
    }
    _byBlock = byBlock;
    _units = units;
    _indexByKey = <Key, int>{
      for (var index = 0; index < units.length; index++)
        units[index].key: index,
    };
  }

  _BlockUnits _buildUnits(PreparedBlock<MessageMarkdownBlock> block) {
    final value = block.value;
    final units = <_Unit>[];
    switch (value.type) {
      case MessageMarkdownBlockType.paragraph:
      case MessageMarkdownBlockType.heading:
      case MessageMarkdownBlockType.code:
      case MessageMarkdownBlockType.quote:
      case MessageMarkdownBlockType.warning:
        _addTextUnits(
          units,
          block: block,
          inline: value.inline,
          text: value.text,
          label: value.language,
        );
      case MessageMarkdownBlockType.unorderedList:
      case MessageMarkdownBlockType.orderedList:
        for (var item = 0; item < value.items.length; item++) {
          _addTextUnits(
            units,
            block: block,
            inline: item < value.itemInline.length
                ? value.itemInline[item]
                : null,
            text: value.items[item],
            marker: value.type == MessageMarkdownBlockType.unorderedList
                ? '•'
                : '${item + 1}.',
          );
        }
      case MessageMarkdownBlockType.table:
        final cellInline = value.cellInline.length == value.rows.length
            ? value.cellInline
            : null;
        for (var row = 0; row < value.rows.length; row++) {
          units.add(
            _TableRowUnit(
              block: block,
              rowIndex: row,
              cells: value.rows[row],
              cellInline: cellInline?[row],
              isHeader: row == 0,
            ),
          );
        }
    }
    return _BlockUnits(block, List<_Unit>.unmodifiable(units));
  }

  /// Adds one prepared field as bounded text slices.
  ///
  /// The slices cut the prepared display when one exists, so the visible text
  /// is exactly the worker's display value; a field without a prepared value
  /// falls back to its own text and renders literally. Each slice carries the
  /// prepared runs that cover it, with run text clipped at the slice boundary,
  /// so a styled run split by the layout keeps its style in every piece.
  void _addTextUnits(
    List<_Unit> units, {
    required PreparedBlock<MessageMarkdownBlock> block,
    required MessageMarkdownInline? inline,
    required String text,
    String marker = '',
    String label = '',
  }) {
    final display = inline?.displayText ?? text;
    final slices = partitionStreamingText(
      display,
      targetLength: widget.targetSliceLength,
    );
    var offset = 0;
    for (var index = 0; index < slices.length; index++) {
      final slice = slices[index];
      units.add(
        _TextUnit(
          block: block,
          sliceIndex: marker.isEmpty ? index : units.length,
          text: slice,
          runs: inline == null
              ? null
              : inline.slice(offset, offset + slice.length),
          marker: marker,
          label: index == 0 ? label : '',
          isFirstSlice: index == 0,
          isLastSlice: index == slices.length - 1,
        ),
      );
      offset += slice.length;
    }
  }

  /// Style mapping of prepared runs for this presenter's own look.
  ///
  /// Flags map to styles only; the raw Markdown is never read here.
  List<InlineSpan> _inlineSpans(
    BuildContext context,
    List<MessageMarkdownInlineRun> runs,
    TextStyle style,
  ) {
    final colors = Theme.of(context).colorScheme;
    return <InlineSpan>[
      for (final run in runs)
        TextSpan(text: run.text, style: _runStyle(colors, run, style)),
    ];
  }

  TextStyle _runStyle(
    ColorScheme colors,
    MessageMarkdownInlineRun run,
    TextStyle style,
  ) {
    var mapped = style;
    if (run.isStrong) {
      mapped = mapped.copyWith(fontWeight: FontWeight.bold);
    }
    if (run.isEmphasis) {
      mapped = mapped.copyWith(fontStyle: FontStyle.italic);
    }
    if (run.isLink) {
      mapped = mapped.copyWith(
        color: colors.primary,
        decoration: TextDecoration.underline,
        decorationColor: colors.primary,
      );
    }
    if (run.isCode) {
      mapped = mapped.copyWith(
        fontFamily: 'monospace',
        fontSize: (style.fontSize ?? 14) - 1,
        backgroundColor: colors.surfaceContainerHighest.withValues(alpha: 0.6),
      );
    }
    return mapped;
  }

  TextStyle _baseStyle(BuildContext context) =>
      widget.style ??
      Theme.of(context).textTheme.bodyMedium ??
      const TextStyle(fontSize: 14, height: 1.5);

  TextStyle _styleFor(BuildContext context, MessageMarkdownBlock block) {
    final base = _baseStyle(context);
    switch (block.type) {
      case MessageMarkdownBlockType.heading:
        final factor = switch (block.level) {
          1 => 1.6,
          2 => 1.4,
          3 => 1.25,
          _ => 1.1,
        };
        return (widget.headingStyle ?? base).copyWith(
          fontSize: (base.fontSize ?? 14) * factor,
          fontWeight: FontWeight.bold,
          height: 1.3,
        );
      case MessageMarkdownBlockType.code:
        return widget.codeStyle ??
            const TextStyle(fontFamily: 'monospace', fontSize: 13, height: 1.4);
      case MessageMarkdownBlockType.quote:
        return widget.quoteStyle ??
            base.copyWith(
              fontStyle: FontStyle.italic,
              color:
                  base.color?.withValues(alpha: 0.8) ?? const Color(0xCC000000),
            );
      case MessageMarkdownBlockType.warning:
        return widget.warningStyle ??
            base.copyWith(
              color: const Color(0xFF8A5300),
              fontWeight: FontWeight.w600,
            );
      case MessageMarkdownBlockType.paragraph:
      case MessageMarkdownBlockType.unorderedList:
      case MessageMarkdownBlockType.orderedList:
      case MessageMarkdownBlockType.table:
        return base;
    }
  }

  Widget _buildTextUnit(BuildContext context, _TextUnit unit) {
    final block = unit.block.value;
    final style = _styleFor(context, block);
    final runs = unit.runs;
    final text = runs == null
        ? Text(unit.text, style: style)
        : Text.rich(TextSpan(children: _inlineSpans(context, runs, style)));

    final Widget body;
    if (unit.marker.isEmpty) {
      body = text;
    } else {
      body = Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${unit.marker} ',
            style:
                widget.markerStyle ??
                _baseStyle(context).copyWith(fontWeight: FontWeight.bold),
          ),
          Expanded(child: text),
        ],
      );
    }

    final Widget labelled = unit.label.isEmpty
        ? body
        : Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                unit.label,
                style: _baseStyle(context).copyWith(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color:
                      _baseStyle(context).color?.withValues(alpha: 0.6) ??
                      const Color(0x99000000),
                ),
              ),
              const SizedBox(height: 6),
              body,
            ],
          );

    final isCode = block.type == MessageMarkdownBlockType.code;
    final isQuote = block.type == MessageMarkdownBlockType.quote;
    final isWarning = block.type == MessageMarkdownBlockType.warning;
    if (!isCode && !isQuote && !isWarning) return labelled;

    // Chrome is applied per slice with no rounded corners, so adjacent slices
    // of one block read as one continuous surface.
    final accent = isCode
        ? const Color(0x1A000000)
        : isQuote
        ? const Color(0x4D000000)
        : const Color(0xFFB26A00);
    return Container(
      width: double.infinity,
      padding: EdgeInsets.only(
        left: 12,
        right: 4,
        top: unit.isFirstSlice ? 8 : 0,
        bottom: unit.isLastSlice ? 8 : 0,
      ),
      decoration: BoxDecoration(
        color: isCode ? const Color(0x0D000000) : null,
        border: Border(left: BorderSide(color: accent, width: 3)),
      ),
      child: labelled,
    );
  }

  Widget _buildTableRow(BuildContext context, _TableRowUnit unit) {
    final base = _baseStyle(context);
    final style = unit.isHeader
        ? (widget.tableHeaderStyle ?? base).copyWith(
            fontWeight: FontWeight.bold,
          )
        : base;
    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Color(0x1A000000))),
      ),
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var cell = 0; cell < unit.cells.length; cell++)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: _tableCell(context, unit, cell, style),
              ),
            ),
        ],
      ),
    );
  }

  Widget _tableCell(
    BuildContext context,
    _TableRowUnit unit,
    int cell,
    TextStyle style,
  ) {
    final inline = unit.cellInline;
    if (inline == null || cell >= inline.length) {
      return Text(unit.cells[cell], style: style);
    }
    return Text.rich(
      TextSpan(children: _inlineSpans(context, inline[cell].runs, style)),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_units.isEmpty) return const SizedBox.shrink();

    Widget content = ListView.builder(
      controller: widget.controller,
      padding: widget.padding,
      shrinkWrap: widget.shrinkWrap,
      physics: widget.shrinkWrap
          ? const NeverScrollableScrollPhysics()
          : widget.physics,
      itemCount: _units.length,
      findChildIndexCallback: (Key key) => _indexByKey[key],
      itemBuilder: (context, index) {
        final unit = _units[index];
        final previous = index == 0 ? null : _units[index - 1];
        final spacing = previous != null && previous.block.id != unit.block.id
            ? widget.blockSpacing
            : 0.0;
        final child = switch (unit) {
          _TextUnit() => _buildTextUnit(context, unit),
          _TableRowUnit() => _buildTableRow(context, unit),
        };
        return Padding(
          key: unit.key,
          padding: EdgeInsets.only(top: spacing),
          child: child,
        );
      },
    );

    if (widget.selectable) {
      content = SelectionArea(child: content);
    }
    if (widget.onCopy != null) {
      content = Semantics(
        container: true,
        onCopy: widget.onCopy,
        child: content,
      );
      if (!widget.selectable) {
        content = GestureDetector(onDoubleTap: widget.onCopy, child: content);
      }
    }
    return RepaintBoundary(child: content);
  }
}
