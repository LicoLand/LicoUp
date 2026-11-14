import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_conversation_overlay_glass.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/contracts/target_candidate.dart';
import 'package:licoup/src/frontend/features/agents/ui/agent_conversation_display_names.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_agent_avatar.dart';
import 'package:licoup/src/frontend/shared/mascot/mascot_catalog.dart';
import 'package:licoup/src/frontend/shared/messaging/messaging_self_avatar.dart';
import 'package:licoup/src/frontend/shared/ui/lico_profile_card.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/continuous_stroke.dart';

/// The demo's `.pop.profile-card` width.
const double messagingMemberProfileCardWidth = 320;

/// Opens a member profile card anchored to [anchorRect] — the member row's
/// global bounds. Mirrors the demo's `mountPop`: try right of the row, then
/// left, then above, then below, clamped inside the window with a 6 px margin.
Future<void> showMessagingMemberProfile({
  required BuildContext context,
  required Rect anchorRect,
  required Widget card,
}) {
  return Navigator.of(
    context,
    rootNavigator: false,
  ).push<void>(_MemberProfileRoute(anchorRect: anchorRect, card: card));
}

final class _MemberProfileRoute extends PopupRoute<void> {
  _MemberProfileRoute({required this.anchorRect, required this.card});

  final Rect anchorRect;
  final Widget card;

  @override
  String? get barrierLabel =>
      MaterialLocalizations.of(navigator!.context).modalBarrierDismissLabel;

  @override
  Color? get barrierColor => Colors.transparent;

  @override
  bool get barrierDismissible => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 160);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    final media = MediaQuery.of(context);
    final delegate = _MemberProfileLayout(
      anchorRect: anchorRect,
      padding: media.padding,
      screenSize: media.size,
    );
    return CustomSingleChildLayout(
      delegate: delegate,
      child: AnimatedBuilder(
        animation: animation,
        builder: (context, child) => Transform.scale(
          scale: 0.96 + 0.04 * animation.value,
          alignment: delegate.alignment,
          child: Opacity(
            opacity: Curves.easeOut.transform(animation.value),
            child: child,
          ),
        ),
        child: Material(type: MaterialType.transparency, child: card),
      ),
    );
  }
}

/// Positions the card like `mountPop`: right of the anchor first, then left,
/// above, below; the first candidate that fits wins, then a 6 px clamp.
final class _MemberProfileLayout extends SingleChildLayoutDelegate {
  _MemberProfileLayout({
    required this.anchorRect,
    required this.padding,
    required this.screenSize,
  });

  final Rect anchorRect;
  final EdgeInsets padding;
  final Size screenSize;

  /// Pop-in transform origin for [Transform.scale], set during layout.
  Alignment alignment = Alignment.centerRight;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) {
    return BoxConstraints(
      maxWidth: messagingMemberProfileCardWidth,
      maxHeight: screenSize.height - padding.vertical - 24,
    );
  }

  @override
  Offset getPositionForChild(Size size, Size childSize) {
    const pad = 10.0;
    const margin = 6.0;
    final minX = padding.left + margin;
    final maxX = screenSize.width - padding.right - margin;
    final minY = padding.top + margin;
    final maxY = screenSize.height - padding.bottom - margin;
    final centeredY = anchorRect.center.dy - childSize.height / 2;
    final candidates = <(Offset, Alignment)>[
      (Offset(anchorRect.right + pad, centeredY), Alignment.centerLeft),
      (
        Offset(anchorRect.left - childSize.width - pad, centeredY),
        Alignment.centerRight,
      ),
      (
        Offset(anchorRect.left, anchorRect.top - childSize.height - pad),
        Alignment.bottomLeft,
      ),
      (Offset(anchorRect.left, anchorRect.bottom + pad), Alignment.topLeft),
    ];
    var (offset, origin) = candidates.last;
    for (final candidate in candidates) {
      final (x, y) = (candidate.$1.dx, candidate.$1.dy);
      // Side candidates hug the anchor's right or left edge even when the
      // centered card would overflow vertically — the clamped Y keeps the
      // card beside the avatar like the demo's anchored popover.
      final isSide =
          candidate.$2 == Alignment.centerLeft ||
          candidate.$2 == Alignment.centerRight;
      final effectiveY = isSide
          ? y.clamp(minY, (maxY - childSize.height).clamp(minY, maxY))
          : y;
      if (x >= minX &&
          x + childSize.width <= maxX &&
          effectiveY >= minY &&
          effectiveY + childSize.height <= maxY) {
        (offset, origin) = (Offset(x, effectiveY), candidate.$2);
        break;
      }
    }
    alignment = origin;
    return Offset(
      offset.dx.clamp(minX, (maxX - childSize.width).clamp(minX, maxX)),
      offset.dy.clamp(minY, (maxY - childSize.height).clamp(minY, maxY)),
    );
  }

  @override
  bool shouldRelayout(covariant _MemberProfileLayout oldDelegate) =>
      anchorRect != oldDelegate.anchorRect ||
      padding != oldDelegate.padding ||
      screenSize != oldDelegate.screenSize;
}

/// One member's profile card content, the Demo `.profile-card` anatomy:
/// gradient cover with stars, ringed avatar overlapping it, name + tag,
/// meta line, status pill, optional description, facts grid, capability
/// chips, optional info rows and note, and an equal-width action row.
final class MessagingMemberProfileCard extends StatelessWidget {
  const MessagingMemberProfileCard({
    super.key,
    required this.avatar,
    required this.name,
    this.tag,
    this.assistantTag = false,
    this.sub,
    this.statusLabel,
    this.statusDot,
    this.description,
    this.facts = const [],
    this.caps = const [],
    this.infoRows = const [],
    this.note,
    this.avatarPicker,
    this.actions = const [],
  });

  /// The 72 px avatar overlapping the cover; wrapped in the gold ring.
  final Widget avatar;
  final String name;
  final String? tag;

  /// Tag tint: assistant uses the accent surface, plain agents the brand one.
  final bool assistantTag;
  final String? sub;
  final String? statusLabel;
  final Color? statusDot;
  final String? description;
  final List<(String, String)> facts;
  final List<String> caps;
  final List<(IconData, String)> infoRows;
  final String? note;

  /// Optional avatar picker (the demo's hidden `.pc-picker`), revealed by a
  /// parent action such as 编辑资料.
  final Widget? avatarPicker;

  /// `.pc-actions` entries; each is laid out with equal width.
  final List<({String label, VoidCallback onPressed, bool filled})> actions;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final textTheme = Theme.of(context).textTheme;
    final bodyChildren = <Widget>[
      Row(
        children: [
          Flexible(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textTheme.titleLarge?.copyWith(
                fontSize: 20,
                fontWeight: FontWeight.w600,
                color: colors.text,
              ),
            ),
          ),
          if (tag != null) ...[
            const SizedBox(width: 8),
            _MemberProfileTag(label: tag!, assistant: assistantTag),
          ],
        ],
      ),
      if (sub != null) ...[
        const SizedBox(height: 2),
        Text(
          sub!,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: textTheme.bodySmall?.copyWith(
            fontSize: 12,
            color: colors.textMuted,
          ),
        ),
      ],
      if (statusLabel != null) ...[
        const SizedBox(height: 9),
        LicoProfileStatusPill(
          label: statusLabel!,
          dotColor: statusDot ?? colors.success,
        ),
      ],
      if (description != null && description!.isNotEmpty) ...[
        const SizedBox(height: 10),
        Text(
          description!,
          style: textTheme.bodySmall?.copyWith(
            fontSize: 13,
            color: colors.textSecondary,
            height: 1.5,
          ),
        ),
      ],
      if (facts.isNotEmpty) ...[
        const SizedBox(height: 12),
        LicoProfileFactGrid(facts: facts),
      ],
      if (caps.isNotEmpty) ...[
        const SizedBox(height: 12),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [for (final cap in caps) LicoProfileCapChip(label: cap)],
        ),
      ],
      ?avatarPicker,
      if (infoRows.isNotEmpty) ...[
        const SizedBox(height: 12),
        for (final (icon, label) in infoRows)
          Padding(
            padding: const EdgeInsets.only(top: 7),
            child: Row(
              children: [
                Icon(icon, size: 14, color: colors.textMuted),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: colors.textSecondary),
                  ),
                ),
              ],
            ),
          ),
      ],
      if (note != null) ...[
        const SizedBox(height: 10),
        Text(
          note!,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 11, color: colors.textDisabled),
        ),
      ],
    ];
    return MessagingConversationOverlayGlass(
      borderRadius: BorderRadius.circular(20),
      readabilityVeil: true,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 112,
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  const Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    height: 76,
                    child: LicoProfileCover(),
                  ),
                  Positioned(
                    top: 40,
                    left: 18,
                    child: LicoProfileAvatarRing(child: avatar),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(18, 12, 18, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: bodyChildren,
                ),
              ),
            ),
            if (actions.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 4, 18, 16),
                child: Row(
                  children: [
                    for (final (index, action) in actions.indexed) ...[
                      if (index > 0) const SizedBox(width: 8),
                      Expanded(
                        child: LicoProfileAction(
                          label: action.label,
                          onPressed: action.onPressed,
                          kind: action.filled
                              ? LicoProfileActionKind.filled
                              : LicoProfileActionKind.quiet,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// The agent member's `.profile-card` body shared by the members panel and
/// the conversation-list avatar affordance: identity, install state, status,
/// adapter/workspace/session facts and capability chips over the same shell.
MessagingMemberProfileCard messagingAgentProfileCard({
  required BuildContext context,
  required LicoStrings strings,
  required TargetCandidate target,
  required String name,
  String? tag,
  bool assistantTag = false,
  String? statusLabel,
  Color? statusDot,
  int? sessionCount,
  List<({String label, VoidCallback onPressed, bool filled})> actions =
      const [],
}) {
  final vendor =
      agentProductDisplayName(target.target) ??
      agentProductDisplayName(target.id) ??
      target.label;
  final installed =
      target.configured || target.status == TargetCandidateStatus.detected;
  final workspace = _pathTail(
    target.location.isNotEmpty ? target.location : target.configPath ?? '',
  );
  final config = _pathTail(target.configPath ?? '');
  return MessagingMemberProfileCard(
    key: Key('member-profile-card-${target.target}'),
    avatar: MessagingAgentAvatar(target: target, size: 72, iconSize: 44),
    name: name,
    tag: tag,
    assistantTag: assistantTag,
    sub: installed
        ? strings.memberProfileVendorInstalled(vendor)
        : strings.memberProfileVendorMissing(vendor),
    statusLabel: statusLabel,
    statusDot: statusDot,
    description: target.detail,
    facts: [
      (
        strings.memberFactAdapter,
        target.adapterStatus.trim().isEmpty
            ? target.kind
            : target.adapterStatus,
      ),
      (strings.memberFactSessions, '${sessionCount ?? 0}'),
      (strings.memberFactWorkspace, workspace.isEmpty ? '—' : workspace),
      (strings.memberFactLocation, config.isEmpty ? '—' : config),
    ],
    caps: target.supportedActions.take(6).toList(growable: false),
    actions: actions,
  );
}

/// The group conversation's `.profile-card`: group mark avatar, title and
/// member count; member chips live on the members panel once the group is
/// open.
MessagingMemberProfileCard messagingGroupProfileCard({
  required LicoStrings strings,
  required String title,
  required int memberCount,
  required Widget avatar,
  List<({String label, VoidCallback onPressed, bool filled})> actions =
      const [],
}) {
  return MessagingMemberProfileCard(
    key: const Key('member-profile-card-group'),
    avatar: avatar,
    name: title,
    sub: strings.groupMembersTitle(memberCount),
    actions: actions,
  );
}

/// The last path component of a workspace or config location; empty input
/// stays empty so the caller can decide the placeholder.
String _pathTail(String path) {
  final trimmed = path.trim();
  if (trimmed.isEmpty) return '';
  final normalized = trimmed.replaceAll('\\', '/');
  final segments = normalized.split('/')
    ..removeWhere((segment) => segment.isEmpty);
  return segments.isEmpty ? normalized : segments.last;
}

final class _MemberProfileTag extends StatelessWidget {
  const _MemberProfileTag({required this.label, required this.assistant});

  final String label;
  final bool assistant;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: assistant ? colors.accentSurface : colors.brandSurface,
        borderRadius: BorderRadius.circular(LicoRadius.chip),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        child: Text(
          label,
          style: TextStyle(
            color: assistant ? colors.accent : colors.textSecondary,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            height: 1.1,
          ),
        ),
      ),
    );
  }
}

/// The self card's mascot picker: the demo's `.pc-picker` 4-column grid of
/// bundled avatars; the current choice carries the brand ring.
final class MessagingMascotPicker extends StatelessWidget {
  const MessagingMascotPicker({
    super.key,
    required this.selected,
    required this.onSelected,
  });

  final String? selected;
  final ValueChanged<String> onSelected;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final chinese = LicoStrings.of(context).isChinese;
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: GridView.count(
        crossAxisCount: 4,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        children: [
          for (final id in MascotCatalog.avatars.keys)
            GestureDetector(
              key: Key('messaging-mascot-pick-$id'),
              onTap: () => onSelected(id),
              child: Semantics(
                button: true,
                label: MascotCatalog.avatarName(id, chinese: chinese),
                child: Container(
                  decoration: continuousHairlineDecoration(
                    borderRadius: BorderRadius.circular(LicoRadius.card),
                    stroke: id == selected ? colors.selectionInk : null,
                    strokeWidth: 2,
                  ),
                  padding: const EdgeInsets.all(2),
                  child: MascotImage.avatar(
                    id,
                    semanticLabel: MascotCatalog.avatarName(
                      id,
                      chinese: chinese,
                    ),
                    size: 60,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// The local user's floating `.profile-card`: the demo's self variant —
/// mascot avatar, display name, status pill, device and identity rows, the
/// local-data note, and the action row. 编辑资料 toggles the bundled mascot
/// picker inside the popover; 设置 follows the settings destination.
final class MessagingSelfProfileCard extends StatefulWidget {
  const MessagingSelfProfileCard({
    super.key,
    required this.displayName,
    this.mascotId,
    this.onMascotChanged,
    this.onOpenSettings,
  });

  /// The resolved local-user display name; callers fall back to
  /// [LicoStrings.memberSelf] when the source is empty.
  final String displayName;
  final String? mascotId;
  final ValueChanged<String>? onMascotChanged;
  final VoidCallback? onOpenSettings;

  @override
  State<MessagingSelfProfileCard> createState() =>
      _MessagingSelfProfileCardState();
}

final class _MessagingSelfProfileCardState
    extends State<MessagingSelfProfileCard> {
  bool _pickerVisible = false;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    return MessagingMemberProfileCard(
      key: const Key('member-profile-card-self'),
      avatar: MessagingSelfAvatar(size: 72, mascotId: widget.mascotId),
      name: widget.displayName,
      statusLabel: strings.memberStatusOnline,
      statusDot: colors.success,
      avatarPicker: _pickerVisible && widget.onMascotChanged != null
          ? MessagingMascotPicker(
              selected: widget.mascotId,
              onSelected: widget.onMascotChanged!,
            )
          : null,
      infoRows: [
        (Icons.monitor_outlined, strings.memberProfileDevice),
        (Icons.verified_user_outlined, strings.memberProfileIdentity),
      ],
      note: strings.memberProfileSelfNote,
      actions: [
        if (widget.onMascotChanged != null)
          (
            label: strings.memberProfileEdit,
            filled: true,
            onPressed: () => setState(() => _pickerVisible = !_pickerVisible),
          ),
        if (widget.onOpenSettings != null)
          (
            label: strings.settings,
            filled: false,
            onPressed: () {
              Navigator.of(context, rootNavigator: false).pop();
              widget.onOpenSettings!();
            },
          ),
      ],
    );
  }
}
