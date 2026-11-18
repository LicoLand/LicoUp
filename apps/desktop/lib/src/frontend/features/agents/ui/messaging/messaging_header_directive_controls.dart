import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_agents_directive.dart';
import 'package:licoup/src/frontend/shared/ui/lico_icon_button.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// Wraps a conversation header's identity capsule content so the whole
/// capsule opens the shell's conversation switcher, with a chevron after the
/// identity. Without a switcher directive the identity renders unchanged.
final class MessagingHeaderSwitcherTrigger extends StatelessWidget {
  const MessagingHeaderSwitcherTrigger({
    super.key,
    required this.identity,
    required this.triggerKey,
  });

  final Widget identity;
  final Key triggerKey;

  @override
  Widget build(BuildContext context) {
    final directive = LayoutAgentsDirectiveScope.maybeOf(context);
    final toggle = directive?.onToggleSwitcher;
    if (toggle == null) return identity;
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final open = directive!.switcherOpen;
    return Semantics(
      button: true,
      expanded: open,
      label: strings.isChinese ? '切换对话' : 'Switch conversation',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          key: triggerKey,
          behavior: HitTestBehavior.opaque,
          onTap: toggle,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(child: identity),
              const SizedBox(width: 6),
              AnimatedRotation(
                turns: open ? 0.5 : 0,
                duration: context.motion(LicoMotion.short),
                curve: LicoMotion.standard,
                child: Icon(
                  Icons.keyboard_arrow_down_rounded,
                  size: 14,
                  color: colors.textMuted,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The header control that collapses the shell's sidebar to its rail; absent
/// unless the shell asks for it.
final class MessagingHeaderCollapseControl extends StatelessWidget {
  const MessagingHeaderCollapseControl({super.key});

  @override
  Widget build(BuildContext context) {
    final collapse = LayoutAgentsDirectiveScope.maybeOf(
      context,
    )?.onCollapseSidebar;
    if (collapse == null) return const SizedBox.shrink();
    final strings = LicoStrings.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: LicoIconButton(
        key: const Key('messaging-header-collapse-sidebar'),
        tooltip: strings.isChinese ? '收起侧栏' : 'Collapse the sidebar',
        onPressed: collapse,
        size: LicoIconButtonSize.compact,
        shape: LicoIconButtonShape.concentric,
        radius: 8,
        tone: LicoIconButtonTone.ghost,
        icon: const Icon(Icons.keyboard_double_arrow_right_rounded),
      ),
    );
  }
}
