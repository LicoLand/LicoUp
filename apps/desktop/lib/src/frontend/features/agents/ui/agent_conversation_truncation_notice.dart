import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

final class ConversationTruncationNotice extends StatelessWidget {
  const ConversationTruncationNotice({
    super.key,
    required this.historyTruncated,
    required this.messageTreeTruncated,
  });

  final bool historyTruncated;
  final bool messageTreeTruncated;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final message = historyTruncated && messageTreeTruncated
        ? strings.conversationHistoryAndDetailsTruncated
        : historyTruncated
        ? strings.conversationHistoryTruncated
        : strings.conversationDetailsTruncated;
    return Semantics(
      container: true,
      label: message,
      child: ExcludeSemantics(
        child: Row(
          children: [
            Icon(Icons.info_outline_rounded, size: 16, color: colors.textMuted),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: TextStyle(color: colors.textMuted, fontSize: 11),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
