import 'package:flutter/material.dart';

import 'package:flutter_client/src/frontend/shared/ui/message_markdown_block_view.dart';
import 'package:flutter_client/src/frontend/shared/ui/message_markdown_parser.dart';
import 'package:flutter_client/src/frontend/shared/ui/message_markdown_style.dart';

export 'package:flutter_client/src/frontend/shared/ui/message_markdown_models.dart';
export 'package:flutter_client/src/frontend/shared/ui/message_markdown_parser.dart';
export 'package:flutter_client/src/frontend/shared/ui/message_markdown_style.dart';

/// Stable composer for parsed message markdown blocks.
final class MessageMarkdown extends StatelessWidget {
  const MessageMarkdown({
    super.key,
    required this.data,
    required this.foreground,
    required this.accent,
    required this.codeBackground,
    required this.blockBackground,
    required this.borderColor,
    this.renderStyle = const MessageMarkdownStyle(),
  });

  final String data;
  final Color foreground;
  final Color accent;
  final Color codeBackground;
  final Color blockBackground;
  final Color borderColor;
  final MessageMarkdownStyle renderStyle;

  @override
  Widget build(BuildContext context) {
    final baseStyle = DefaultTextStyle.of(context).style.copyWith(
      color: foreground,
      height: renderStyle.bodyLineHeight,
      fontSize: renderStyle.bodyFontSize,
      letterSpacing: 0,
    );
    final blocks = parseMessageMarkdownBlocks(data);
    if (blocks.isEmpty) return Text('', style: baseStyle);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (var index = 0; index < blocks.length; index++) ...[
          MessageMarkdownBlockView(
            block: blocks[index],
            baseStyle: baseStyle,
            foreground: foreground,
            accent: accent,
            codeBackground: codeBackground,
            blockBackground: blockBackground,
            borderColor: borderColor,
            renderStyle: renderStyle,
          ),
          if (index != blocks.length - 1)
            SizedBox(height: renderStyle.blockSpacing),
        ],
      ],
    );
  }
}
