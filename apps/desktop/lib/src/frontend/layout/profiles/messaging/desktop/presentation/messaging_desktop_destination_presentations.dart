import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/layout/layout_destination_presentation.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';
import 'package:licoup/src/frontend/layout/profiles/messaging/desktop/tokens/messaging_desktop_tokens.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';

/// Destinations whose body sits flush on the shell [MessagingMainContentCard]
/// glass wash. These use a transparent canvas so the card's veil shows through;
/// they do not paint an opaque surface fill inside the card.
const Set<ClientSection> messagingMainContentCardDestinations =
    <ClientSection>{
      ClientSection.agents,
      ClientSection.skillHub,
      ClientSection.pluginManagement,
      ClientSection.monitoring,
      ClientSection.models,
      ClientSection.mobileRelay,
      ClientSection.settings,
    };

const LayoutAgentsPresentation messagingDesktopAgentsPresentation =
    MessagingDesktopAgentsPresentation();
const LayoutSettingsPresentation messagingDesktopSettingsPresentation =
    MessagingDesktopSettingsPresentation();

/// Messaging desktop Agents: Telegram-style framing — the shell main content
/// card is the glass conversation surface; the list sits in a nested floating
/// glass card; the chat pane is flush with that card. The list IS the
/// sidebar, so no collapse controls are offered.
final class MessagingDesktopAgentsPresentation
    implements LayoutAgentsPresentation {
  const MessagingDesktopAgentsPresentation();

  /// Transparent so the main content card's glass wash shows through as the
  /// shared conversation background (list card floats above it).
  @override
  Color canvasColor(LayoutPalette palette) => Colors.transparent;

  @override
  double get sidebarOuterHorizontalExtent =>
      MessagingDesktopMetrics.conversationListCardInset;

  @override
  double get detailOuterHorizontalExtent => 0;

  @override
  EdgeInsetsGeometry get expandedSidebarControlPadding => EdgeInsets.zero;

  @override
  EdgeInsetsGeometry get collapsedSidebarControlPadding => EdgeInsets.zero;

  @override
  bool get showExpandedSidebarControl => false;

  @override
  bool get showCollapsedSidebarControl => false;

  @override
  bool get showConversationSidebarControl => false;

  @override
  Widget frameWorkspace(
    BuildContext context, {
    required Key key,
    required Widget child,
  }) => KeyedSubtree(key: key, child: child);

  @override
  Widget frameSidebar(
    BuildContext context, {
    required Key key,
    required Widget child,
  }) {
    final colors = context.layoutPalette;
    const inset = MessagingDesktopMetrics.conversationListCardInset;
    const radius = MessagingDesktopMetrics.conversationListCardCornerRadius;
    return Padding(
      padding: const EdgeInsets.fromLTRB(inset, inset, 0, inset),
      child: DecoratedBox(
        key: key,
        decoration: BoxDecoration(
          // Translucent wash over the shared chat canvas — no BackdropFilter
          // so the card stays crisp on the opaque pane fill. Geometry and
          // wash alphas come from MessagingDesktopMetrics only.
          color: MessagingDesktopMetrics.conversationListCardFill(
            isDark: colors.isDark,
          ),
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(
            color: MessagingDesktopMetrics.conversationListCardBorder(
              colors.line,
              isDark: colors.isDark,
            ),
            width: MessagingDesktopMetrics.hairline,
          ),
          boxShadow: MessagingDesktopMetrics.conversationListCardShadows(
            isDark: colors.isDark,
          ),
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(radius),
          child: child,
        ),
      ),
    );
  }

  @override
  Widget frameDetail(
    BuildContext context, {
    required Key key,
    required bool sidebarCollapsed,
    required Widget child,
  }) => KeyedSubtree(key: key, child: child);
}

/// Messaging desktop Settings: transparent canvas on the shell main content
/// card; section index and content share the glass wash like other destinations.
final class MessagingDesktopSettingsPresentation
    implements LayoutSettingsPresentation {
  const MessagingDesktopSettingsPresentation();

  @override
  bool get indexHostedByNavigation => false;

  @override
  EdgeInsetsGeometry get contentPadding => EdgeInsets.zero;

  @override
  EdgeInsetsGeometry get indexPadding =>
      const EdgeInsets.symmetric(vertical: LicoContentSpacing.compact);

  @override
  EdgeInsetsGeometry get sectionHeaderPadding => const EdgeInsets.fromLTRB(
    20,
    LicoContentSpacing.section,
    20,
    LicoContentSpacing.inline,
  );

  @override
  EdgeInsetsGeometry get rowPadding =>
      const EdgeInsets.fromLTRB(20, LicoContentSpacing.item, 20, 0);

  @override
  EdgeInsetsGeometry get selectorGridPadding =>
      const EdgeInsets.only(top: LicoContentSpacing.item);

  @override
  EdgeInsetsGeometry get selectorActionPadding => const EdgeInsets.fromLTRB(
    LicoContentSpacing.item,
    0,
    LicoContentSpacing.item,
    LicoContentSpacing.compact,
  );

  @override
  Widget frameIndex(
    BuildContext context, {
    required bool hovered,
    required Widget child,
  }) => child;

  @override
  Widget frameSection(
    BuildContext context, {
    required Key key,
    required Widget child,
  }) => KeyedSubtree(key: key, child: child);

  @override
  Widget frameSelector(BuildContext context, {required Widget child}) => child;
}
