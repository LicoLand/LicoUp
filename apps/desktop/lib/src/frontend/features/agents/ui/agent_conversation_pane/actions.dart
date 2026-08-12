import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/lico_icon_button.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

class AgentConversationWelcome extends StatelessWidget {
  const AgentConversationWelcome({
    super.key,
    required this.onNewConversation,
    required this.onNewGroupConversation,
    required this.onOpenMobilePairing,
    required this.onOpenSettings,
  });

  final VoidCallback? onNewConversation;
  final VoidCallback onNewGroupConversation;
  final VoidCallback onOpenMobilePairing;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                strings.welcome,
                key: const Key('agent-conversation-welcome-title'),
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                  color: context.licoColors.text,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 28),
              GridView.count(
                key: const Key('agent-conversation-welcome-actions'),
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                crossAxisCount: 2,
                crossAxisSpacing: 12,
                mainAxisSpacing: 12,
                childAspectRatio: 1.45,
                children: [
                  _WelcomeActionCard(
                    key: const Key('welcome-new-conversation'),
                    icon: Icons.add_comment_outlined,
                    label: strings.newConversation,
                    onTap: onNewConversation,
                  ),
                  _WelcomeActionCard(
                    key: const Key('welcome-mobile-pairing'),
                    icon: Icons.phonelink_ring_outlined,
                    label: strings.mobileAppPairing,
                    onTap: onOpenMobilePairing,
                  ),
                  _WelcomeActionCard(
                    key: const Key('welcome-new-group-conversation'),
                    icon: Icons.group_add_outlined,
                    label: strings.welcomeNewGroupConversation,
                    onTap: onNewGroupConversation,
                  ),
                  _WelcomeActionCard(
                    key: const Key('welcome-settings'),
                    icon: Icons.settings_outlined,
                    label: strings.settings,
                    onTap: onOpenSettings,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _WelcomeActionCard extends StatelessWidget {
  const _WelcomeActionCard({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final enabled = onTap != null;
    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: Material(
        color: colors.surfaceLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(LicoRadius.card),
          side: BorderSide(color: colors.line),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, size: 28, color: colors.text),
                const SizedBox(height: 12),
                Text(
                  label,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.text,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
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
