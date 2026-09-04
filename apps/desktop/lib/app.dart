import 'dart:async';
import 'dart:ui' show ViewFocusEvent, ViewFocusState;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'src/composition/client_app_composition.dart';
import 'src/frontend/binding/projection_builder.dart';
import 'src/frontend/binding/projection_telemetry_scope.dart';
import 'src/frontend/locale/locale_projection_adapter.dart';
import 'src/frontend/l10n/lico_strings.dart';
import 'src/frontend/features/agents/ui/agent_render_adapter.dart';
import 'src/frontend/shared/appearance/appearance_preset_config.dart';
import 'src/frontend/appearance/appearance_projection_adapter.dart';
import 'src/frontend/shared/ui/theme.dart';
import 'src/frontend/shell/client_shell.dart';
import 'src/frontend/binding/shell_renderer_port.dart';
import 'src/platform/agent_render_adapter/agent_render_adapter_service.dart';
import 'src/presentation/shell/shell_projection.dart';
import 'src/presentation/shell/shell_binding.dart';

class LicoApp extends StatefulWidget {
  const LicoApp({
    super.key,
    this.compositionFactory,
    this.initializeController = true,
    this.homeBuilder,
  });

  /// Test and acceptance seam for exercising the real application shell with
  /// a bounded backend. Production callers omit this and always use the
  /// platform-backed composition.
  final ClientAppComposition Function()? compositionFactory;

  /// Acceptance controllers may be fully staged before the first frame. The
  /// production entry point keeps the default and performs normal bootstrap.
  final bool initializeController;

  /// Bounded root-renderer seam for state-plane tests. Production always uses
  /// [ClientShell].
  final Widget Function(
    BuildContext context,
    ShellBinding binding,
    ShellRendererPort renderer,
  )?
  homeBuilder;

  @override
  State<LicoApp> createState() => _LicoAppState();
}

class _LicoAppState extends State<LicoApp> with WidgetsBindingObserver {
  late final ClientAppComposition _composition;
  int? _viewId;

  @override
  void initState() {
    super.initState();
    AgentRenderAdapterRegistry.instance = AgentRenderAdapterRegistry(
      jsonSource: DefaultAgentRenderAdapterJsonSource(),
    );
    _composition = widget.compositionFactory?.call() ?? ClientAppComposition();
    _composition.attachFlutterObservation(WidgetsBinding.instance);
    WidgetsBinding.instance.addObserver(this);
    _composition.updateConversationAttention(
      lifecycleState:
          WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed,
    );
    if (widget.initializeController) {
      unawaited(_composition.initialize());
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_composition.initializeLlmGateway());
      });
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _viewId = View.of(context).viewId;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _composition.updateConversationAttention(lifecycleState: state);
  }

  @override
  void didChangeViewFocus(ViewFocusEvent event) {
    if (_viewId != null && event.viewId != _viewId) {
      return;
    }
    _composition.updateConversationAttention(
      viewFocused: event.state == ViewFocusState.focused,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_composition.dispose());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final app = ProjectionBuilder<AppearanceProjection, AppearanceProjection>(
      source: _composition.binding.appearance,
      select: _appearanceProjection,
      builder: (context, appearance) {
        final presets = appearancePresetConfigsFromProjection(appearance);
        final presetId = appearance.presetId;
        return ProjectionBuilder<LocaleProjection, LocaleProjection>(
          source: _composition.binding.locale,
          select: _localeProjection,
          builder: (context, locale) => MaterialApp(
            onGenerateTitle: (context) => LicoStrings.of(context).appTitle,
            debugShowCheckedModeBanner: false,
            supportedLocales: LicoStrings.supportedLocales,
            locale: localeFromProjection(locale),
            localeListResolutionCallback: (locales, supportedLocales) {
              return LicoStrings.resolvePreferred(locales);
            },
            localizationsDelegates: const [
              GlobalMaterialLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
            ],
            themeMode: themeModeForAppearance(presetId, presets),
            theme: buildLicoTheme(
              presetId: presetId,
              presets: presets,
              platformBrightness: Brightness.light,
            ),
            darkTheme: buildLicoTheme(
              presetId: presetId,
              presets: presets,
              platformBrightness: Brightness.dark,
            ),
            home:
                widget.homeBuilder?.call(
                  context,
                  _composition.binding,
                  _composition.renderer,
                ) ??
                ClientShell(
                  binding: _composition.binding,
                  renderer: _composition.renderer,
                ),
          ),
        );
      },
    );
    final telemetry = _composition.telemetry;
    return telemetry == null
        ? app
        : ProjectionTelemetryScope(observer: telemetry, child: app);
  }
}

AppearanceProjection _appearanceProjection(AppearanceProjection value) => value;

LocaleProjection _localeProjection(LocaleProjection value) => value;
