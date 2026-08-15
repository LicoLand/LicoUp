import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/apple_control_metrics.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/lico_icon_button.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

/// Colors for the shared search capsule. Messaging chrome supplies glass
/// tokens; feature panes use the theme defaults from [of].
final class LicoSearchCapsuleColors {
  const LicoSearchCapsuleColors({
    required this.fill,
    required this.border,
    required this.icon,
    required this.hint,
    required this.text,
  });

  factory LicoSearchCapsuleColors.of(BuildContext context) {
    final colors = context.licoColors;
    return LicoSearchCapsuleColors(
      fill: colors.surfaceLow,
      border: colors.line,
      icon: colors.textMuted,
      hint: colors.textMuted,
      text: colors.text,
    );
  }

  final Color fill;
  final Color border;
  final Color icon;
  final Color hint;
  final Color text;
}

/// Pill search chrome: magnifying glass, hint, hairline rim, quiet fill.
///
/// Tap-to-open surfaces ([LicoSearchCapsule]) and in-pane fields
/// ([LicoSearchField]) share this decoration so every search control reads
/// as one component.
final class LicoSearchChrome extends StatelessWidget {
  const LicoSearchChrome({
    super.key,
    required this.child,
    this.colors,
    this.width,
    this.height = LicoSearchChrome.extent,
  });

  /// Matches [LicoIconButtonSize.medium.extent] so title-bar search lines up
  /// with [LicoPaneRefreshButton].
  static const double extent = 32;

  final Widget child;
  final LicoSearchCapsuleColors? colors;
  final double? width;
  final double height;

  @override
  Widget build(BuildContext context) {
    final resolved = colors ?? LicoSearchCapsuleColors.of(context);
    final radius = BorderRadius.circular(height / 2);
    return SizedBox(
      width: width,
      height: height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: resolved.fill,
          borderRadius: radius,
          border: Border.all(
            color: resolved.border,
            width: AppleControlMetrics.hairline,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: LicoContentSpacing.item,
          ),
          child: child,
        ),
      ),
    );
  }
}

/// Tap-to-open search capsule used by the conversation sidebar and feature
/// pane title bars. Bind [onTap] to destination-specific search logic.
final class LicoSearchCapsule extends StatelessWidget {
  const LicoSearchCapsule({
    super.key,
    required this.onTap,
    this.hintText,
    this.colors,
    this.width,
  });

  final VoidCallback onTap;
  final String? hintText;
  final LicoSearchCapsuleColors? colors;
  final double? width;

  @override
  Widget build(BuildContext context) {
    final resolved = colors ?? LicoSearchCapsuleColors.of(context);
    final strings = LicoStrings.of(context);
    final radius = BorderRadius.circular(LicoSearchChrome.extent / 2);
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: radius,
        onTap: onTap,
        child: LicoSearchChrome(
          colors: resolved,
          width: width,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.search_rounded,
                size: 15,
                color: resolved.icon,
                applyTextScaling: false,
              ),
              const SizedBox(width: LicoContentSpacing.compact),
              Flexible(
                child: Text(
                  hintText ?? strings.sidebarSearchHint,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: resolved.hint,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w400,
                    height: 1.0,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Editable search field that inherits [LicoSearchChrome]. Sidebar and
/// palette surfaces bind their own query handling; this widget is only the
/// shared chrome.
final class LicoSearchField extends StatelessWidget {
  const LicoSearchField({
    super.key,
    required this.onChanged,
    this.controller,
    this.query = '',
    this.hintText,
    this.colors,
    this.width,
  });

  final TextEditingController? controller;
  final String query;
  final String? hintText;
  final ValueChanged<String> onChanged;
  final LicoSearchCapsuleColors? colors;
  final double? width;

  @override
  Widget build(BuildContext context) {
    final resolved = colors ?? LicoSearchCapsuleColors.of(context);
    final strings = LicoStrings.of(context);
    return LicoSearchChrome(
      colors: resolved,
      width: width,
      child: Row(
        children: [
          Icon(
            Icons.search_rounded,
            size: 15,
            color: resolved.icon,
            applyTextScaling: false,
          ),
          const SizedBox(width: LicoContentSpacing.compact),
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: onChanged,
              textInputAction: TextInputAction.search,
              cursorOpacityAnimates: false,
              cursorColor: resolved.text,
              style: TextStyle(
                color: resolved.text,
                fontSize: 12.5,
                fontWeight: FontWeight.w400,
                height: 1.0,
              ),
              decoration: InputDecoration(
                isDense: true,
                isCollapsed: true,
                border: InputBorder.none,
                hintText: hintText ?? strings.sidebarSearchHint,
                hintStyle: TextStyle(
                  color: resolved.hint,
                  fontSize: 12.5,
                  fontWeight: FontWeight.w400,
                  height: 1.0,
                ),
              ),
            ),
          ),
          if (query.isNotEmpty)
            LicoIconButton(
              tooltip: strings.clearSearch,
              onPressed: () {
                controller?.clear();
                onChanged('');
              },
              size: LicoIconButtonSize.small,
              shape: LicoIconButtonShape.circle,
              tone: LicoIconButtonTone.ghost,
              icon: Icon(Icons.close, size: 14, color: resolved.icon),
            ),
        ],
      ),
    );
  }
}
