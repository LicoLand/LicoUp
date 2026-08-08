import 'package:flutter/material.dart';

final class MessageMarkdownStyle {
  const MessageMarkdownStyle({
    this.bodyFontSize = 14,
    this.bodyLineHeight = 1.35,
    this.blockSpacing = 8,
    this.heading1FontSize = 18,
    this.heading2FontSize = 16,
    this.heading3FontSize = 15,
    this.headingLineHeight = 1.25,
    this.headingWeight = FontWeight.w900,
    this.codeFontSize = 13,
    this.codeLineHeight = 1.35,
    this.codeRadius = 6,
    this.codePadding = 10,
    this.showCodeLanguage = false,
    this.quoteRadius = 6,
    this.quotePaddingX = 10,
    this.quotePaddingY = 8,
    this.listMarkerWidth = 22,
    this.orderedListMarkerWidth = 30,
    this.listItemSpacing = 5,
    this.unorderedMarker = '-',
  });

  final double bodyFontSize;
  final double bodyLineHeight;
  final double blockSpacing;
  final double heading1FontSize;
  final double heading2FontSize;
  final double heading3FontSize;
  final double headingLineHeight;
  final FontWeight headingWeight;
  final double codeFontSize;
  final double codeLineHeight;
  final double codeRadius;
  final double codePadding;
  final bool showCodeLanguage;
  final double quoteRadius;
  final double quotePaddingX;
  final double quotePaddingY;
  final double listMarkerWidth;
  final double orderedListMarkerWidth;
  final double listItemSpacing;
  final String unorderedMarker;
}
