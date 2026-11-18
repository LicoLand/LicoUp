import 'dart:collection';

import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/shared/ui/message_markdown_models.dart';
import 'package:licoup/src/frontend/shared/ui/message_markdown_style.dart';

/// Bounded cache for the style mapping of prepared inline displays.
///
/// Mapping turns the prepared runs into styled spans for the current theme; it
/// never reads or tokenizes Markdown text. The prepared value keeps its
/// identity across rebuilds, so a repaint maps the same runs again and gets
/// the identical span tree: the renderer's own layout cache stays valid and a
/// theme change costs one mapping pass, not a re-parse.
final LinkedHashMap<_InlineSpanCacheKey, List<InlineSpan>> _inlineSpanCache =
    LinkedHashMap();
const int _inlineSpanCacheLimit = 512;

/// Maps one prepared inline display to styled spans.
///
/// [inline] is the worker-prepared display value; this function only applies
/// [style] plus the flag decorations to each run. It has no access to the raw
/// Markdown source, so a renderer cannot re-tokenize it here.
List<InlineSpan> messageMarkdownInlineSpans(
  MessageMarkdownInline inline,
  TextStyle style, {
  required Color accent,
  required Color codeBackground,
}) {
  final key = _InlineSpanCacheKey(inline, style, accent, codeBackground);
  final cached = _inlineSpanCache.remove(key);
  if (cached != null) {
    // Refresh recency: LRU eviction drops the least recently used entry.
    _inlineSpanCache[key] = cached;
    return cached;
  }
  final spans = List<InlineSpan>.unmodifiable(<InlineSpan>[
    for (final run in inline.runs)
      TextSpan(
        text: run.text,
        style: messageMarkdownInlineRunStyle(
          run,
          style,
          accent: accent,
          codeBackground: codeBackground,
        ),
      ),
  ]);
  if (_inlineSpanCache.length >= _inlineSpanCacheLimit) {
    _inlineSpanCache.remove(_inlineSpanCache.keys.first);
  }
  _inlineSpanCache[key] = spans;
  return spans;
}

/// The style one prepared run renders with.
///
/// The flags apply in the order the source markup nests them, so a code span
/// inside strong text keeps its weight while taking the code font, size, and
/// background.
TextStyle messageMarkdownInlineRunStyle(
  MessageMarkdownInlineRun run,
  TextStyle style, {
  required Color accent,
  required Color codeBackground,
}) {
  var mapped = style;
  if (run.isStrong) {
    mapped = mapped.copyWith(fontWeight: FontWeight.w800);
  }
  if (run.isEmphasis) {
    mapped = mapped.copyWith(fontStyle: FontStyle.italic);
  }
  if (run.isLink) {
    mapped = mapped.copyWith(
      color: accent,
      decoration: TextDecoration.underline,
      decorationColor: accent,
    );
  }
  if (run.isCode) {
    mapped = mapped.copyWith(
      fontFamily: 'SF Mono',
      fontFamilyFallback: const ['Menlo', 'Consolas', 'monospace'],
      fontSize: (style.fontSize ?? 14) - 1,
      backgroundColor: codeBackground,
    );
  }
  return mapped;
}

TextStyle messageMarkdownHeadingStyle(
  TextStyle baseStyle,
  int level,
  MessageMarkdownStyle renderStyle,
) {
  return baseStyle.copyWith(
    fontSize: switch (level) {
      1 => renderStyle.heading1FontSize,
      2 => renderStyle.heading2FontSize,
      _ => renderStyle.heading3FontSize,
    },
    height: renderStyle.headingLineHeight,
    fontWeight: renderStyle.headingWeight,
  );
}

/// Cache key of one style mapping.
///
/// The prepared display is shared across rebuilds, so its object identity is
/// the content identity; the styles compare by value because a restyle must
/// map the same prepared value again.
final class _InlineSpanCacheKey {
  const _InlineSpanCacheKey(
    this.inline,
    this.style,
    this.accent,
    this.codeBackground,
  );

  final MessageMarkdownInline inline;
  final TextStyle style;
  final Color accent;
  final Color codeBackground;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _InlineSpanCacheKey &&
          identical(other.inline, inline) &&
          other.style == style &&
          other.accent == accent &&
          other.codeBackground == codeBackground;

  @override
  int get hashCode =>
      Object.hash(identityHashCode(inline), style, accent, codeBackground);
}
