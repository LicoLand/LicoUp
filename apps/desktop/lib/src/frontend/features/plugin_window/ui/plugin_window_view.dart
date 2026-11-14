import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:licoup/src/contracts/plugin_window_host_models.dart';
import 'package:licoup/src/frontend/shared/ui/lico_pane_card.dart';
import 'package:licoup/src/frontend/binding/projection_builder.dart';
import 'package:licoup/src/frontend/features/agents/ui/messaging/messaging_glass_option_card.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/shared/mascot/mascot_catalog.dart';
import 'package:licoup/src/frontend/shared/ui/apple_buttons.dart';
import 'package:licoup/src/frontend/shared/ui/continuous_stroke.dart';
import 'package:licoup/src/frontend/shared/ui/lico_motion.dart';
import 'package:licoup/src/frontend/shared/ui/lico_skeleton.dart';
import 'package:licoup/src/frontend/shared/ui/theme_colors.dart';
import 'package:licoup/src/presentation/plugin_window/plugin_window_binding.dart';
import 'package:licoup/src/presentation/plugin_window/plugin_window_intent.dart';
import 'package:licoup/src/presentation/plugin_window/plugin_window_projection.dart';
import 'package:licoup/src/presentation/presentation_semantics.dart';

/// Builds the adapter-supplied platform view of a ready plugin window.
typedef PluginWindowContentBuilder =
    Widget Function(BuildContext context, PluginWindowContentView content);

/// The platform view named by the host adapter. Platforms without a
/// platform-view host never reach the ready state: their adapter reports
/// unsupported.
Widget buildPluginWindowPlatformView(
  BuildContext context,
  PluginWindowContentView content,
) => switch (defaultTargetPlatform) {
  TargetPlatform.macOS => AppKitView(
    viewType: content.viewType,
    creationParams: content.parameters,
    creationParamsCodec: const StandardMessageCodec(),
  ),
  TargetPlatform.iOS => UiKitView(
    viewType: content.viewType,
    creationParams: content.parameters,
    creationParamsCodec: const StandardMessageCodec(),
  ),
  TargetPlatform.android => AndroidView(
    viewType: content.viewType,
    creationParams: content.parameters,
    creationParamsCodec: const StandardMessageCodec(),
  ),
  _ => const _PluginWindowUnsupported(),
};

typedef _WindowSlice = ({
  PresentationPhase phase,
  PluginWindowManifest? manifest,
  PluginWindowSessionProjection? session,
});

/// The content area of one plugin window: the platform view once ready, and
/// the loading, permission, error, offline and unsupported states around it.
final class PluginWindowView extends StatelessWidget {
  const PluginWindowView({
    super.key,
    required this.binding,
    required this.pluginId,
    this.contentBuilder = buildPluginWindowPlatformView,
  });

  final PluginWindowBinding binding;
  final String pluginId;
  final PluginWindowContentBuilder contentBuilder;

  @override
  Widget build(BuildContext context) =>
      ProjectionBuilder<PluginWindowProjection, _WindowSlice>(
        source: binding.projection,
        select: (projection) => (
          phase: projection.phase,
          manifest: projection.manifest(pluginId),
          session: projection.session(pluginId),
        ),
        builder: (context, slice) => KeyedSubtree(
          key: ValueKey<String>('plugin-window-$pluginId'),
          child: _body(context, slice),
        ),
      );

  Widget _body(BuildContext context, _WindowSlice slice) {
    final strings = LicoStrings.of(context);
    final manifest = slice.manifest;
    final session = slice.session;
    if (manifest == null) {
      if (slice.phase == PresentationPhase.loading) {
        return const _PluginWindowLoading(progress: null);
      }
      return _PluginWindowMessage(
        key: const Key('plugin-window-not-installed'),
        leading: _StateGlyph(Icons.extension_off_outlined),
        title: strings.pluginWindowNotInstalled,
      );
    }
    if (session == null) {
      return const _PluginWindowLoading(progress: null);
    }
    void reload() => binding.intents.send(ReloadPluginWindow(pluginId));
    return switch (session.status) {
      PluginWindowStatus.loading => _PluginWindowLoading(
        progress: session.progress,
      ),
      PluginWindowStatus.ready => KeyedSubtree(
        key: const Key('plugin-window-ready'),
        child: contentBuilder(context, session.content!),
      ),
      PluginWindowStatus.permissionRequest => Stack(
        fit: StackFit.expand,
        children: [
          const _PluginWindowLoading(progress: null, showHairline: false),
          _PermissionSheet(
            pluginName: manifest.name,
            capability: session.permissionCapability,
            detail: session.permissionDetail,
            onDecide: (decision) => binding.intents.send(
              DecidePluginWindowPermission(pluginId, decision),
            ),
          ),
        ],
      ),
      PluginWindowStatus.error => _PluginWindowMessage(
        key: const Key('plugin-window-error'),
        leading: MascotImage.expression(
          'sorry',
          semanticLabel: strings.pluginWindowErrorTitle,
          size: 112,
        ),
        title: strings.pluginWindowErrorTitle,
        message: strings.pluginWindowErrorMessage,
        caption: session.errorCode.isEmpty
            ? null
            : strings.pluginWindowErrorCode(session.errorCode),
        action: AppleGlassActionButton(
          key: const Key('plugin-window-error-reload'),
          label: strings.pluginWindowReload,
          icon: Icons.refresh_rounded,
          emphasized: true,
          onPressed: reload,
        ),
      ),
      PluginWindowStatus.offline => _PluginWindowMessage(
        key: const Key('plugin-window-offline'),
        leading: _StateGlyph(Icons.wifi_off_rounded),
        title: strings.pluginWindowOfflineTitle,
        message: strings.pluginWindowOfflineMessage,
        action: AppleGlassActionButton(
          key: const Key('plugin-window-offline-reload'),
          label: strings.pluginWindowReload,
          icon: Icons.refresh_rounded,
          onPressed: reload,
        ),
      ),
      PluginWindowStatus.unsupported => const _PluginWindowUnsupported(),
    };
  }
}

final class _PluginWindowUnsupported extends StatelessWidget {
  const _PluginWindowUnsupported();

  @override
  Widget build(BuildContext context) {
    final strings = LicoStrings.of(context);
    return _PluginWindowMessage(
      key: const Key('plugin-window-unsupported'),
      leading: _StateGlyph(Icons.web_asset_off_outlined),
      title: strings.pluginWindowUnsupportedTitle,
      message: strings.pluginWindowUnsupportedMessage,
    );
  }
}

/// Skeleton of a typical plugin page under a 2px progress hairline.
final class _PluginWindowLoading extends StatelessWidget {
  const _PluginWindowLoading({
    required this.progress,
    this.showHairline = true,
  });

  /// Determinate progress in `[0, 1]`; null while indeterminate.
  final double? progress;
  final bool showHairline;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    // An indeterminate hairline loops; reduced motion shows a static
    // partial bar instead of a sped-up loop.
    final value =
        progress ?? (context.allowsAmbientMotion ? null : _staticProgress);
    return Semantics(
      key: const Key('plugin-window-loading'),
      label: strings.pluginWindowLoading,
      liveRegion: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 2,
            child: showHairline
                ? LinearProgressIndicator(
                    key: const Key('plugin-window-progress'),
                    value: value,
                    minHeight: 2,
                    color: colors.primary,
                    backgroundColor: Colors.transparent,
                  )
                : null,
          ),
          Expanded(
            child: ExcludeSemantics(
              child: SingleChildScrollView(
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(24, 22, 24, 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const LicoSkeleton(width: 220, height: 18),
                    const SizedBox(height: 18),
                    const LicoSkeleton(width: double.infinity, height: 72),
                    const SizedBox(height: 18),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final columns = constraints.maxWidth >= 560 ? 3 : 2;
                        const gap = 12.0;
                        final width =
                            (constraints.maxWidth - gap * (columns - 1)) /
                            columns;
                        return Wrap(
                          spacing: gap,
                          runSpacing: gap,
                          children: [
                            for (var index = 0; index < columns * 2; index++)
                              SizedBox(
                                width: width,
                                child: const Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    LicoSkeleton(
                                      width: double.infinity,
                                      height: 64,
                                    ),
                                    SizedBox(height: 8),
                                    LicoSkeleton.line(width: 120),
                                  ],
                                ),
                              ),
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  static const double _staticProgress = 0.3;
}

/// The permission request sliding down from the window's title row.
final class _PermissionSheet extends StatelessWidget {
  const _PermissionSheet({
    required this.pluginName,
    required this.capability,
    required this.detail,
    required this.onDecide,
  });

  final String pluginName;
  final String capability;
  final String detail;
  final ValueChanged<PluginPermissionDecision> onDecide;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final strings = LicoStrings.of(context);
    final textTheme = Theme.of(context).textTheme;
    final title = strings.pluginWindowPermissionTitle(
      pluginName,
      strings.pluginWindowCapabilityLabel(capability),
    );
    final sheet = Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: MessagingGlassOptionCard(
          key: const Key('plugin-window-permission-sheet'),
          borderRadius: const BorderRadius.vertical(
            bottom: Radius.circular(16),
          ),
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 14),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.shield_outlined,
                    size: 18,
                    color: colors.accentStrong,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      title,
                      style: textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: colors.text,
                      ),
                    ),
                  ),
                ],
              ),
              if (detail.isNotEmpty) ...[
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.only(left: 28),
                  child: Text(
                    detail,
                    style: textTheme.bodySmall?.copyWith(
                      color: colors.textSecondary,
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 14),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  AppleGlassActionButton(
                    key: const Key('plugin-window-permission-deny'),
                    label: strings.pluginWindowDeny,
                    onPressed: () => onDecide(PluginPermissionDecision.deny),
                  ),
                  AppleGlassActionButton(
                    key: const Key('plugin-window-permission-once'),
                    label: strings.pluginWindowAllowOnce,
                    onPressed: () =>
                        onDecide(PluginPermissionDecision.allowOnce),
                  ),
                  AppleGlassActionButton(
                    key: const Key('plugin-window-permission-always'),
                    label: strings.pluginWindowAllowAlways,
                    emphasized: true,
                    onPressed: () =>
                        onDecide(PluginPermissionDecision.allowAlways),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    return Align(
      alignment: Alignment.topCenter,
      child: ClipRect(
        child: TweenAnimationBuilder<double>(
          tween: Tween<double>(begin: 0, end: 1),
          duration: context.motion(LicoMotion.medium),
          curve: LicoMotion.decelerate,
          builder: (context, t, child) => FractionalTranslation(
            translation: Offset(0, t - 1),
            child: child,
          ),
          child: Semantics(
            container: true,
            liveRegion: true,
            label: title,
            child: sheet,
          ),
        ),
      ),
    );
  }
}

final class _StateGlyph extends StatelessWidget {
  const _StateGlyph(this.icon);

  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    return Container(
      width: 64,
      height: 64,
      decoration: continuousHairlineDecoration(
        color: (colors.isDark
            ? LicoPaneGlass.contentInnerCardFill
            : colors.surfaceLow),
        borderRadius: BorderRadius.circular(999),
        stroke: colors.line,
      ),
      child: Icon(icon, size: 28, color: colors.textMuted),
    );
  }
}

final class _PluginWindowMessage extends StatelessWidget {
  const _PluginWindowMessage({
    super.key,
    required this.leading,
    required this.title,
    this.message,
    this.caption,
    this.action,
  });

  final Widget leading;
  final String title;
  final String? message;
  final String? caption;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final colors = context.licoColors;
    final textTheme = Theme.of(context).textTheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(28),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 380),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ExcludeSemantics(child: leading),
              const SizedBox(height: 16),
              Text(
                title,
                textAlign: TextAlign.center,
                style: textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: colors.text,
                ),
              ),
              if (message != null) ...[
                const SizedBox(height: 6),
                Text(
                  message!,
                  textAlign: TextAlign.center,
                  style: textTheme.bodySmall?.copyWith(
                    color: colors.textSecondary,
                    height: 1.45,
                  ),
                ),
              ],
              if (caption != null) ...[
                const SizedBox(height: 8),
                SelectableText(
                  caption!,
                  textAlign: TextAlign.center,
                  style: textTheme.labelSmall?.copyWith(
                    color: colors.textMuted,
                  ),
                ),
              ],
              if (action != null) ...[const SizedBox(height: 18), action!],
            ],
          ),
        ),
      ),
    );
  }
}
