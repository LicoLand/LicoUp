import 'package:flutter/widgets.dart';

import 'theme_colors.dart';

/// The list typeface scale a layout × theme set renders. Every set without
/// a declaration keeps [baseline] — today's exact literals, moved into the
/// ramp. [graded] grades by information value for the dark Dashboard sets.
enum LicoListTypography { baseline, graded }

/// Declares which [LicoListTypography] scale rows under this scope render.
final class LicoListTypographyScope extends InheritedWidget {
  const LicoListTypographyScope({
    super.key,
    required this.typography,
    required super.child,
  });

  final LicoListTypography typography;

  static LicoListTypography of(BuildContext context) =>
      context
          .dependOnInheritedWidgetOfExactType<LicoListTypographyScope>()
          ?.typography ??
      LicoListTypography.baseline;

  @override
  bool updateShouldNotify(LicoListTypographyScope oldWidget) =>
      oldWidget.typography != typography;
}

/// The resolved list-row type roles for the ambient [LicoListTypography].
///
/// Every role is a finished `TextStyle` — size and weight come from a role,
/// never from an inline literal (`lico_typography.dart`'s rule). Colour is
/// part of the role for graded roles; semantic colours (status, unread
/// badge) stay owned by their own channels.
final class LicoListTypeRamp {
  const LicoListTypeRamp._({
    required this.title,
    required this.titleUnread,
    required this.preview,
    required this.previewUnread,
    required this.descriptor,
    required this.placeholder,
    required this.meta,
    required this.metaUnread,
    required this.tag,
    required this.quietTags,
    required this.memberCountAsText,
    required this.status,
    required this.indexLabel,
    required this.indexLabelSelected,
    required this.indexIconColor,
    required this.denseIndexLabel,
    required this.denseIndexLabelSelected,
    required this.childTitle,
    required this.childTitleSelected,
    required this.childMeta,
    required this.childMetaSelected,
    required this.navLabel,
    required this.navLabelSelected,
    required this.chipLabel,
    required this.chipLabelSelected,
  });

  /// Row title.
  final TextStyle title;

  /// Row title on an unread row.
  final TextStyle titleUnread;

  /// Real conversation preview line.
  final TextStyle preview;

  /// Preview on an unread row.
  final TextStyle previewUnread;

  /// Static subtitle: "群聊", a profile row's backing-agent product name.
  final TextStyle descriptor;

  /// The no-conversation placeholder ("还没有对话").
  final TextStyle placeholder;

  /// Timestamps, counts, tabular metadata.
  final TextStyle meta;

  /// Metadata on an unread row.
  final TextStyle metaUnread;

  /// Text style for row tags ("AI" and similar).
  final TextStyle tag;

  /// Whether tags render as quiet hairline text instead of filled chips.
  final bool quietTags;

  /// Whether the member count renders as plain meta text instead of a chip.
  final bool memberCountAsText;

  /// Status labels (working/approval/finished) — size and weight only;
  /// colour stays semantic.
  final TextStyle status;

  /// Sidebar index-row label, unselected.
  final TextStyle indexLabel;

  /// Sidebar index-row label, selected.
  final TextStyle indexLabelSelected;

  /// Unselected index-row icon colour (selected keeps `selectionInk`).
  final Color indexIconColor;

  /// Dense index-item label (settings panel), unselected.
  final TextStyle denseIndexLabel;

  /// Dense index-item label (settings panel), selected.
  final TextStyle denseIndexLabelSelected;

  /// Archived/continuity child-row title (group sidebar), unselected.
  final TextStyle childTitle;

  /// Archived/continuity child-row title, selected.
  final TextStyle childTitleSelected;

  /// Child-row meta (member count), unselected.
  final TextStyle childMeta;

  /// Child-row meta, selected.
  final TextStyle childMetaSelected;

  /// Bottom-nav label, unselected.
  final TextStyle navLabel;

  /// Bottom-nav label, selected.
  final TextStyle navLabelSelected;

  /// Filter-chip label, unselected.
  final TextStyle chipLabel;

  /// Filter-chip label, selected.
  final TextStyle chipLabelSelected;

  /// Resolves the ramp for the ambient typography scope.
  static LicoListTypeRamp of(BuildContext context) =>
      LicoListTypographyScope.of(context) == LicoListTypography.graded
      ? LicoListTypeRamp.graded(context.licoColors)
      : LicoListTypeRamp.baseline(context.licoColors);

  /// Today's literals — every set renders pixel-identical under baseline.
  factory LicoListTypeRamp.baseline(LicoThemeColors colors) =>
      LicoListTypeRamp._(
        title: TextStyle(
          color: colors.text,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
        titleUnread: TextStyle(
          color: colors.text,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
        preview: TextStyle(color: colors.textMuted, fontSize: 13),
        previewUnread: TextStyle(color: colors.textMuted, fontSize: 13),
        descriptor: TextStyle(color: colors.textMuted, fontSize: 13),
        placeholder: TextStyle(color: colors.textMuted, fontSize: 13),
        meta: TextStyle(
          color: colors.textMuted,
          fontSize: 12,
          fontWeight: FontWeight.w400,
        ),
        metaUnread: TextStyle(
          color: colors.textMuted,
          fontSize: 12,
          fontWeight: FontWeight.w400,
        ),
        tag: TextStyle(fontSize: 10, fontWeight: FontWeight.w700),
        quietTags: false,
        memberCountAsText: false,
        status: TextStyle(color: colors.textMuted, fontSize: 11),
        indexLabel: TextStyle(
          color: colors.text,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
        indexLabelSelected: TextStyle(
          color: colors.selectionInk,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
        indexIconColor: colors.text,
        denseIndexLabel: TextStyle(
          color: colors.text,
          fontSize: 12.5,
          fontWeight: FontWeight.w500,
        ),
        denseIndexLabelSelected: TextStyle(
          color: colors.selectionInk,
          fontSize: 12.5,
          fontWeight: FontWeight.w700,
        ),
        childTitle: TextStyle(
          color: colors.text,
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
        ),
        childTitleSelected: TextStyle(
          color: colors.selectionInk,
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
        ),
        childMeta: TextStyle(color: colors.textMuted, fontSize: 10.5),
        childMetaSelected: TextStyle(
          color: colors.selectionInk.withAlpha(180),
          fontSize: 10.5,
        ),
        navLabel: const TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w500,
          height: 1.1,
        ),
        navLabelSelected: const TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          height: 1.1,
        ),
        chipLabel: TextStyle(
          color: colors.textSecondary,
          fontSize: 12,
          fontWeight: FontWeight.w500,
          height: 1.35,
        ),
        chipLabelSelected: TextStyle(
          color: colors.text,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          height: 1.35,
        ),
      );

  /// Direction A — grade by information value (dark Dashboard sets).
  factory LicoListTypeRamp.graded(LicoThemeColors colors) => LicoListTypeRamp._(
    title: TextStyle(
      color: colors.text,
      fontSize: 15,
      fontWeight: FontWeight.w600,
      letterSpacing: -0.2,
    ),
    titleUnread: TextStyle(
      color: colors.text,
      fontSize: 15,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.2,
    ),
    preview: TextStyle(
      color: colors.textSecondary,
      fontSize: 12.5,
      fontWeight: FontWeight.w400,
      height: 1.3,
    ),
    previewUnread: TextStyle(
      color: colors.text,
      fontSize: 12.5,
      fontWeight: FontWeight.w400,
      height: 1.3,
    ),
    descriptor: TextStyle(
      color: colors.textMuted,
      fontSize: 12.5,
      fontWeight: FontWeight.w400,
    ),
    placeholder: TextStyle(
      color: colors.textMuted.withValues(alpha: 0.62),
      fontSize: 12,
      fontWeight: FontWeight.w400,
    ),
    meta: TextStyle(
      color: colors.textMuted,
      fontSize: 11,
      fontWeight: FontWeight.w500,
      fontFeatures: const [FontFeature.tabularFigures()],
    ),
    metaUnread: TextStyle(
      color: colors.selectionInk,
      fontSize: 11,
      fontWeight: FontWeight.w500,
      fontFeatures: const [FontFeature.tabularFigures()],
    ),
    tag: TextStyle(
      color: colors.textMuted,
      fontSize: 9.5,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.4,
    ),
    quietTags: true,
    memberCountAsText: true,
    status: TextStyle(
      color: colors.textMuted,
      fontSize: 11,
      fontWeight: FontWeight.w600,
    ),
    indexLabel: TextStyle(
      color: colors.textSecondary,
      fontSize: 14,
      fontWeight: FontWeight.w500,
    ),
    indexLabelSelected: TextStyle(
      color: colors.selectionInk,
      fontSize: 14,
      fontWeight: FontWeight.w600,
    ),
    indexIconColor: colors.textSecondary,
    denseIndexLabel: TextStyle(
      color: colors.textSecondary,
      fontSize: 14,
      fontWeight: FontWeight.w500,
    ),
    denseIndexLabelSelected: TextStyle(
      color: colors.selectionInk,
      fontSize: 14,
      fontWeight: FontWeight.w600,
    ),
    childTitle: TextStyle(
      color: colors.textSecondary,
      fontSize: 13,
      fontWeight: FontWeight.w500,
    ),
    childTitleSelected: TextStyle(
      color: colors.selectionInk,
      fontSize: 13,
      fontWeight: FontWeight.w600,
    ),
    childMeta: TextStyle(color: colors.textMuted, fontSize: 10.5),
    childMetaSelected: TextStyle(
      color: colors.selectionInk.withAlpha(180),
      fontSize: 10.5,
    ),
    navLabel: TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.2,
      height: 1.1,
    ),
    navLabelSelected: TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w700,
      letterSpacing: 0.2,
      height: 1.1,
    ),
    chipLabel: TextStyle(
      color: colors.textSecondary,
      fontSize: 12,
      fontWeight: FontWeight.w500,
      height: 1.35,
    ),
    chipLabelSelected: TextStyle(
      color: colors.text,
      fontSize: 12,
      fontWeight: FontWeight.w600,
      height: 1.35,
    ),
  );
}
