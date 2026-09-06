import 'package:flutter/material.dart';

import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_palette.dart';

/// The Dashboard desktop's local profile page: a quiet card-canvas surface
/// with the local-user avatar and a few quick actions that reuse existing
/// surfaces (device pairing, appearance & layout settings). There is no
/// account system; the page represents the local user only.
final class DashboardProfilePage extends StatelessWidget {
  const DashboardProfilePage({
    super.key,
    required this.onOpenPairing,
    required this.onOpenSettings,
  });

  final VoidCallback onOpenPairing;
  final VoidCallback onOpenSettings;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    final strings = LicoStrings.of(context);
    return ColoredBox(
      key: const Key('dashboard-profile-page'),
      color: Colors.transparent,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 340),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Center(
                child: Container(
                  width: 72,
                  height: 72,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: colors.primary.withAlpha(colors.isDark ? 44 : 28),
                  ),
                  child: Center(
                    child: Icon(
                      Icons.person_outline_rounded,
                      size: 36,
                      color: colors.accentStrong,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 14),
              Center(
                child: Text(
                  strings.localUser,
                  style: TextStyle(
                    color: colors.text,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Center(
                child: Text(
                  strings.appTitle,
                  style: TextStyle(
                    color: colors.textMuted,
                    fontSize: 12,
                    fontWeight: FontWeight.w400,
                  ),
                ),
              ),
              const SizedBox(height: 28),
              _DashboardProfileActionRow(
                key: const Key('dashboard-profile-pairing-action'),
                icon: Icons.qr_code_2_rounded,
                label: strings.pairDevice,
                onTap: onOpenPairing,
              ),
              const SizedBox(height: 8),
              _DashboardProfileActionRow(
                key: const Key('dashboard-profile-settings-action'),
                icon: Icons.tune_outlined,
                label: strings.appearanceAndLayout,
                onTap: onOpenSettings,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _DashboardProfileActionRow extends StatelessWidget {
  const _DashboardProfileActionRow({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.layoutPalette;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        hoverColor: colors.isDark
            ? Colors.white.withAlpha(10)
            : Colors.black.withAlpha(8),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: colors.isDark
                ? Colors.white.withAlpha(8)
                : Colors.black.withAlpha(5),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: colors.line.withAlpha(90), width: 0.5),
          ),
          child: Row(
            children: [
              Icon(icon, size: 18, color: colors.textSecondary),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: colors.text,
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                size: 18,
                color: colors.textMuted,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
