import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// Truncates [summary] to [maxLines] and keeps the visit control on the last
/// visible line, after an ellipsis when the copy overflows.
final class AgentHubSummaryVisit extends StatelessWidget {
  const AgentHubSummaryVisit({
    super.key,
    required this.summaryKey,
    required this.visitKey,
    required this.summary,
    required this.visitLabel,
    required this.visitFailedLabel,
    required this.visitFailed,
    required this.visitEnabled,
    required this.onVisit,
  });

  static const int maxLines = 3;
  static const double fontSize = 12;
  static const double lineHeight = 1.4;
  static const double reservedHeight = fontSize * lineHeight * maxLines;

  final Key summaryKey;
  final Key visitKey;
  final String summary;
  final String visitLabel;
  final String visitFailedLabel;
  final bool visitFailed;
  final bool visitEnabled;
  final VoidCallback onVisit;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final textTheme = Theme.of(context).textTheme;
    final summaryStyle =
        textTheme.bodySmall?.copyWith(
          color: colors.textMuted,
          fontSize: fontSize,
          height: lineHeight,
        ) ??
        TextStyle(
          color: colors.textMuted,
          fontSize: fontSize,
          height: lineHeight,
        );
    final visitStyle = summaryStyle.copyWith(
      color: colors.error,
      fontWeight: FontWeight.w600,
    );
    final iconSize = fontSize;
    const gap = 4.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final reserved = visitFailed
            ? _measureText(visitFailedLabel, visitStyle) + gap
            : iconSize + gap;
        final fitted = _fitSummary(
          summary: summary,
          reserved: reserved,
          summaryStyle: summaryStyle,
          maxWidth: constraints.maxWidth,
          maxHeight: constraints.maxHeight,
        );
        return Text.rich(
          TextSpan(
            children: [
              TextSpan(text: fitted.text, style: summaryStyle),
              if (fitted.ellipsis) TextSpan(text: '...', style: summaryStyle),
              WidgetSpan(
                alignment: PlaceholderAlignment.middle,
                child: Padding(
                  padding: const EdgeInsets.only(left: gap),
                  child: visitFailed
                      ? Text(visitFailedLabel, key: visitKey, style: visitStyle)
                      : Tooltip(
                          message: visitLabel,
                          child: GestureDetector(
                            key: visitKey,
                            onTap: visitEnabled ? onVisit : null,
                            child: Icon(
                              Icons.open_in_new,
                              size: iconSize,
                              color: visitEnabled
                                  ? colors.accent
                                  : colors.textDisabled,
                            ),
                          ),
                        ),
                ),
              ),
            ],
          ),
          key: summaryKey,
          maxLines: maxLines,
          overflow: TextOverflow.ellipsis,
          softWrap: true,
        );
      },
    );
  }
}

final class _FittedSummary {
  const _FittedSummary({required this.text, required this.ellipsis});

  final String text;
  final bool ellipsis;
}

double _measureText(String text, TextStyle style) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout();
  return painter.width;
}

_FittedSummary _fitSummary({
  required String summary,
  required double reserved,
  required TextStyle summaryStyle,
  required double maxWidth,
  required double maxHeight,
}) {
  final fontSize = summaryStyle.fontSize ?? AgentHubSummaryVisit.fontSize;
  final lineHeight =
      fontSize * (summaryStyle.height ?? AgentHubSummaryVisit.lineHeight);
  final boundedHeight = maxHeight.isFinite && maxHeight > 0
      ? maxHeight
      : lineHeight * AgentHubSummaryVisit.maxLines;
  final maxLines = math.min(
    AgentHubSummaryVisit.maxLines,
    math.max(1, (boundedHeight / lineHeight).floor()),
  );
  final width = maxWidth.isFinite && maxWidth > 0 ? maxWidth : 240.0;

  bool fits(String text, {required bool ellipsis}) {
    final shown = ellipsis ? '$text...' : text;
    final painter = TextPainter(
      text: TextSpan(text: shown, style: summaryStyle),
      textDirection: TextDirection.ltr,
      maxLines: maxLines,
    )..layout(maxWidth: width);
    if (painter.didExceedMaxLines) {
      return false;
    }
    final metrics = painter.computeLineMetrics();
    if (metrics.isEmpty) {
      return reserved <= width;
    }
    return metrics.last.width + reserved <= width + 0.5;
  }

  if (fits(summary, ellipsis: false)) {
    return _FittedSummary(
      text: summary.isEmpty ? '' : '$summary ',
      ellipsis: false,
    );
  }

  var lo = 0;
  var hi = summary.length;
  var best = 0;
  while (lo <= hi) {
    final mid = (lo + hi) ~/ 2;
    final candidate = summary.substring(0, mid).trimRight();
    if (fits(candidate, ellipsis: true)) {
      best = candidate.length;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  final truncated = summary.substring(0, best).trimRight();
  return _FittedSummary(text: truncated, ellipsis: true);
}
