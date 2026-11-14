import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/shared/ui/lico_icon_button.dart';

class ArchiveAgentConversationsButton extends StatelessWidget {
  const ArchiveAgentConversationsButton({
    super.key,
    required this.busy,
    required this.tooltip,
    required this.onPressed,
  });

  final bool busy;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return LicoIconButton(
      key: key,
      tooltip: tooltip,
      onPressed: busy ? null : onPressed,
      busy: busy,
      icon: const Icon(Icons.archive_outlined),
    );
  }
}

class NewAgentConversationButton extends StatelessWidget {
  const NewAgentConversationButton({
    super.key,
    required this.enabled,
    required this.tooltip,
    required this.onPressed,
  });

  final bool enabled;
  final String tooltip;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    // The default ghost tone — muted at rest, full text colour on hover —
    // replaces the old lemon glyph, which violated the rule that the brand is
    // never a text or glyph colour (it rendered at 1.40:1 on a light surface).
    return LicoIconButton(
      key: key,
      tooltip: tooltip,
      onPressed: enabled ? onPressed : null,
      icon: const Icon(Icons.add_comment_outlined),
    );
  }
}
