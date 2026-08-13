import 'dart:async';

import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/ui/lico_content_spacing.dart';
import 'package:licoup/src/frontend/shared/ui/lico_radius.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';

class DirectoryPathField extends StatelessWidget {
  const DirectoryPathField({
    super.key,
    required this.title,
    required this.label,
    required this.onOpen,
    this.icon = Icons.folder_outlined,
    this.path,
    this.controller,
    this.subtitle,
    this.enabled = true,
    this.readOnly = false,
    this.busy = false,
    this.openEnabled = true,
    this.showHeader = true,
    this.compactBreakpoint = 620,
    this.actions = const [],
    this.headerTrailing,
    this.valueTextStyle,
    this.padding = const EdgeInsets.fromLTRB(
      LicoContentSpacing.item,
      LicoContentSpacing.compact,
      LicoContentSpacing.item,
      LicoContentSpacing.item,
    ),
  }) : assert(path != null || controller != null);

  final String title;
  final String label;
  final String? path;
  final TextEditingController? controller;
  final String? subtitle;
  final IconData icon;
  final bool enabled;
  final bool readOnly;
  final bool busy;
  final bool openEnabled;
  final bool showHeader;
  final double compactBreakpoint;
  final List<Widget> actions;
  final Widget? headerTrailing;
  final TextStyle? valueTextStyle;
  final FutureOr<void> Function(String path) onOpen;
  final EdgeInsetsGeometry padding;

  String get _currentPath {
    final value = (controller?.text ?? path ?? '').trim();
    return value == '-' ? '' : value;
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final currentPath = _currentPath;
    return Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (showHeader) ...[
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Icon(icon, color: colors.textSecondary, size: 18),
                const SizedBox(width: LicoContentSpacing.compact),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: colors.text,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (subtitle != null && subtitle!.trim().isNotEmpty) ...[
                        const SizedBox(height: LicoContentSpacing.inline / 2),
                        Text(
                          subtitle!.trim(),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: colors.textMuted,
                            fontSize: 12,
                            fontWeight: FontWeight.w400,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                if (headerTrailing != null) ...[
                  const SizedBox(width: LicoContentSpacing.compact),
                  headerTrailing!,
                ],
              ],
            ),
            const SizedBox(height: LicoContentSpacing.compact),
          ],
          LayoutBuilder(
            builder: (context, constraints) {
              final compact = constraints.maxWidth < compactBreakpoint;
              final input = _PathInput(
                label: label,
                path: path,
                controller: controller,
                enabled: enabled && !busy,
                readOnly: readOnly,
                openTooltip: strings.openDirectory,
                valueTextStyle: valueTextStyle,
                onOpen: openEnabled && currentPath.isNotEmpty
                    ? () => unawaited(Future.sync(() => onOpen(currentPath)))
                    : null,
              );
              final actionRow = Wrap(
                spacing: LicoContentSpacing.compact,
                runSpacing: LicoContentSpacing.compact,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: actions,
              );
              if (actions.isEmpty) {
                return input;
              }
              if (compact) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    input,
                    const SizedBox(height: LicoContentSpacing.item),
                    Align(alignment: Alignment.centerLeft, child: actionRow),
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(child: input),
                  const SizedBox(width: LicoContentSpacing.item),
                  actionRow,
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _PathInput extends StatelessWidget {
  const _PathInput({
    required this.label,
    required this.path,
    required this.controller,
    required this.enabled,
    required this.readOnly,
    required this.openTooltip,
    required this.valueTextStyle,
    required this.onOpen,
  });

  final String label;
  final String? path;
  final TextEditingController? controller;
  final bool enabled;
  final bool readOnly;
  final String openTooltip;
  final TextStyle? valueTextStyle;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final canOpen = enabled && onOpen != null;
    final borderColor = enabled
        ? colors.line
        : colors.line.withValues(alpha: 0.55);
    final backgroundColor = enabled
        ? colors.surface
        : colors.surfaceLow.withValues(alpha: 0.72);
    final textStyle = (valueTextStyle ?? Theme.of(context).textTheme.bodyMedium)
        ?.copyWith(
          color: enabled ? colors.text : colors.textMuted,
          fontWeight: valueTextStyle?.fontWeight ?? FontWeight.w500,
          fontSize: 12,
        );
    final hintStyle = (valueTextStyle ?? Theme.of(context).textTheme.bodyMedium)
        ?.copyWith(
          color: colors.textMuted,
          fontWeight: valueTextStyle?.fontWeight ?? FontWeight.w400,
          fontSize: 12,
        );
    final openButton = Tooltip(
      message: openTooltip,
      child: Padding(
        padding: const EdgeInsets.only(right: LicoContentSpacing.inline),
        child: Material(
          color: canOpen ? colors.brandSurface : colors.surfaceLow,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            customBorder: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(6),
            ),
            onTap: canOpen ? onOpen : null,
            child: SizedBox(
              width: 30,
              height: 30,
              child: Icon(
                Icons.open_in_new_outlined,
                size: 14,
                color: canOpen ? colors.accent : colors.textMuted,
              ),
            ),
          ),
        ),
      ),
    );

    Widget valueChild;
    if (controller != null && !readOnly) {
      valueChild = Align(
        alignment: Alignment.centerLeft,
        child: SizedBox(
          height: 12,
          width: double.infinity,
          child: Theme(
            data: Theme.of(context).copyWith(
              inputDecorationTheme: const InputDecorationTheme(
                filled: false,
                fillColor: Colors.transparent,
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                disabledBorder: InputBorder.none,
                errorBorder: InputBorder.none,
                focusedErrorBorder: InputBorder.none,
                contentPadding: EdgeInsets.zero,
                isDense: true,
                isCollapsed: true,
              ),
            ),
            child: TextField(
              controller: controller,
              enabled: enabled,
              maxLines: 1,
              readOnly: readOnly,
              style: textStyle?.copyWith(height: 1.0),
              decoration: InputDecoration.collapsed(
                hintText: label,
                hintStyle: hintStyle?.copyWith(height: 1.0),
              ),
            ),
          ),
        ),
      );
    } else {
      final value = (controller?.text ?? path ?? '').trim();
      valueChild = Align(
        alignment: Alignment.centerLeft,
        child: SizedBox(
          height: 12,
          width: double.infinity,
          child: Tooltip(
            message: value,
            child: Text(
              value.isEmpty ? '-' : value,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: textStyle?.copyWith(height: 1.0),
            ),
          ),
        ),
      );
    }

    return Semantics(
      label: label,
      textField: controller != null && !readOnly,
      child: Container(
        height: 38,
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(LicoRadius.chip),
          border: Border.all(color: borderColor),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(
                  left: LicoContentSpacing.item,
                  right: LicoContentSpacing.compact,
                ),
                child: valueChild,
              ),
            ),
            Center(child: openButton),
          ],
        ),
      ),
    );
  }
}
