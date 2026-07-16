import 'package:flutter/material.dart';

import 'package:flutter_client/src/frontend/shared/ui/message_markdown_style.dart';

List<InlineSpan> messageMarkdownInlineSpans(
  String text,
  TextStyle style, {
  required Color accent,
  required Color codeBackground,
}) {
  final spans = <InlineSpan>[];
  var index = 0;
  while (index < text.length) {
    if (text.startsWith('`', index)) {
      final end = text.indexOf('`', index + 1);
      if (end > index + 1) {
        spans.add(
          TextSpan(
            text: text.substring(index + 1, end),
            style: style.copyWith(
              fontFamily: 'SF Mono',
              fontFamilyFallback: const ['Menlo', 'Consolas', 'monospace'],
              fontSize: (style.fontSize ?? 14) - 1,
              backgroundColor: codeBackground,
            ),
          ),
        );
        index = end + 1;
        continue;
      }
    }
    if (text.startsWith('[', index)) {
      final labelEnd = text.indexOf('](', index + 1);
      if (labelEnd > index + 1) {
        final urlEnd = text.indexOf(')', labelEnd + 2);
        if (urlEnd > labelEnd + 2) {
          spans.add(
            TextSpan(
              text: text.substring(index + 1, labelEnd),
              style: style.copyWith(
                color: accent,
                decoration: TextDecoration.underline,
                decorationColor: accent,
              ),
            ),
          );
          index = urlEnd + 1;
          continue;
        }
      }
    }
    final strong =
        _emphasisMatch(text, index, '**') ?? _emphasisMatch(text, index, '__');
    if (strong != null) {
      spans.addAll(
        messageMarkdownInlineSpans(
          strong.text,
          style.copyWith(fontWeight: FontWeight.w800),
          accent: accent,
          codeBackground: codeBackground,
        ),
      );
      index = strong.end;
      continue;
    }
    final emphasis =
        _emphasisMatch(text, index, '*') ?? _emphasisMatch(text, index, '_');
    if (emphasis != null) {
      spans.addAll(
        messageMarkdownInlineSpans(
          emphasis.text,
          style.copyWith(fontStyle: FontStyle.italic),
          accent: accent,
          codeBackground: codeBackground,
        ),
      );
      index = emphasis.end;
      continue;
    }
    final next = _nextMarkdownMarker(text, index + 1);
    spans.add(TextSpan(text: text.substring(index, next), style: style));
    index = next;
  }
  return spans;
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

_EmphasisMatch? _emphasisMatch(String text, int index, String marker) {
  if (!text.startsWith(marker, index)) return null;
  if (marker.length == 1 &&
      index + 1 < text.length &&
      text.startsWith(marker, index + 1)) {
    return null;
  }
  final end = text.indexOf(marker, index + marker.length);
  if (end <= index + marker.length) return null;
  return _EmphasisMatch(
    text.substring(index + marker.length, end),
    end + marker.length,
  );
}

int _nextMarkdownMarker(String text, int start) {
  final candidates =
      ['`', '[', '**', '__', '*', '_']
          .map((marker) => text.indexOf(marker, start))
          .where((candidate) => candidate >= 0)
          .toList(growable: false)
        ..sort();
  return candidates.isEmpty ? text.length : candidates.first;
}

final class _EmphasisMatch {
  const _EmphasisMatch(this.text, this.end);

  final String text;
  final int end;
}
