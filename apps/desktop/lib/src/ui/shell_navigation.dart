import 'package:flutter/material.dart';

import '../controllers/future_client_controller.dart';
import '../l10n/lico_strings.dart';
import '../models/future_client_models.dart';
import 'theme.dart';

const _navLabelStyle = TextStyle(
  fontFamily: 'Microsoft YaHei UI',
  fontFamilyFallback: [
    'Microsoft YaHei',
    'PingFang SC',
    'Noto Sans CJK SC',
    'Noto Sans SC',
    'Segoe UI',
    'Arial',
    'sans-serif',
  ],
  fontWeight: FontWeight.w600,
  letterSpacing: 0,
);

class ShellSidebar extends StatelessWidget {
  const ShellSidebar({
    super.key,
    required this.current,
    required this.compact,
    required this.onSelect,
  });

  final FutureClientSection current;
  final bool compact;
  final ValueChanged<FutureClientSection> onSelect;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final items = [
      (FutureClientSection.agents, strings.agents, Icons.smart_toy_outlined),
      (
        FutureClientSection.mcpPlugins,
        strings.mcpPlugins,
        Icons.extension_outlined,
      ),
      (
        FutureClientSection.skillHub,
        strings.skillHub,
        Icons.library_books_outlined,
      ),
      (
        FutureClientSection.modelForwarding,
        strings.modelForwarding,
        Icons.send_outlined,
      ),
      (
        FutureClientSection.mobileRelay,
        strings.mobileRelay,
        Icons.phone_iphone_outlined,
      ),
      (FutureClientSection.activity, strings.activity, Icons.history_outlined),
      (FutureClientSection.localRuntime, strings.runtime, Icons.dns_outlined),
      (FutureClientSection.settings, strings.settings, Icons.settings_outlined),
    ];
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
      width: compact ? 64 : 220,
      decoration: BoxDecoration(
        color: colors.surfaceLow,
        border: Border(right: BorderSide(color: colors.line)),
      ),
      padding: EdgeInsets.all(compact ? 8 : 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: EdgeInsets.fromLTRB(8, 8, 8, compact ? 12 : 18),
            child: Text(
              compact ? 'P' : 'LicoLite',
              textAlign: compact ? TextAlign.center : TextAlign.start,
              style: TextStyle(
                color: colors.primary,
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
          for (final item in items)
            _NavButton(
              selected: current == item.$1,
              icon: item.$3,
              label: item.$2,
              compact: compact,
              onPressed: () => onSelect(item.$1),
            ),
        ],
      ),
    );
  }
}

class ShellTopBar extends StatelessWidget {
  const ShellTopBar({super.key, required this.section});

  final FutureClientSection section;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final title = switch (section) {
      FutureClientSection.agents => strings.agents,
      FutureClientSection.mcpPlugins => strings.mcpPlugins,
      FutureClientSection.skillHub => strings.skillHub,
      FutureClientSection.modelForwarding => strings.modelForwarding,
      FutureClientSection.localRuntime => strings.runtime,
      FutureClientSection.mobileRelay => strings.mobileRelay,
      FutureClientSection.activity => strings.activity,
      FutureClientSection.settings => strings.settings,
    };
    return Container(
      height: 64,
      alignment: Alignment.centerLeft,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      decoration: BoxDecoration(
        color: colors.background,
        border: Border(bottom: BorderSide(color: colors.line)),
      ),
      child: Text(
        title,
        style: Theme.of(
          context,
        ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
      ),
    );
  }
}

class ShellStatusBar extends StatelessWidget {
  const ShellStatusBar({super.key, required this.controller});

  final FutureClientController controller;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: colors.surfaceLow,
        border: Border(top: BorderSide(color: colors.line)),
      ),
      child: Text(
        controller.statusMessage.isEmpty
            ? controller.statusCaption
            : controller.statusMessage,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: Theme.of(context).textTheme.bodySmall,
      ),
    );
  }
}

class _NavButton extends StatelessWidget {
  const _NavButton({
    required this.selected,
    required this.icon,
    required this.label,
    required this.compact,
    required this.onPressed,
  });

  final bool selected;
  final IconData icon;
  final String label;
  final bool compact;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Tooltip(
        message: compact ? label : '',
        waitDuration: const Duration(milliseconds: 450),
        child: compact
            ? IconButton(
                isSelected: selected,
                tooltip: label,
                onPressed: onPressed,
                color: selected ? colors.primary : colors.text,
                style: IconButton.styleFrom(
                  backgroundColor: selected
                      ? colors.primaryFixed
                      : Colors.transparent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  fixedSize: const Size(44, 42),
                ),
                icon: Icon(icon, size: 19),
              )
            : TextButton.icon(
                onPressed: onPressed,
                icon: Icon(icon, size: 18),
                label: Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: _navLabelStyle,
                  ),
                ),
                style: TextButton.styleFrom(
                  alignment: Alignment.centerLeft,
                  foregroundColor: selected ? colors.primary : colors.text,
                  backgroundColor: selected
                      ? colors.primaryFixed
                      : Colors.transparent,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  minimumSize: const Size.fromHeight(42),
                  textStyle: _navLabelStyle,
                ),
              ),
      ),
    );
  }
}
