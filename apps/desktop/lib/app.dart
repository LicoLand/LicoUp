import 'dart:async';
import 'dart:ui' show ViewFocusEvent, ViewFocusState;

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import 'src/application/controller/client_controller.dart';
import 'src/frontend/l10n/lico_strings.dart';
import 'src/frontend/features/agents/ui/agent_render_adapter.dart';
import 'src/frontend/shared/appearance/appearance_preset_config.dart';
import 'src/frontend/shared/ui/theme.dart';
import 'src/frontend/shell/client_shell.dart';
import 'src/platform/agent_render_adapter/agent_render_adapter_service.dart';

class LicoApp extends StatefulWidget {
  const LicoApp({
    super.key,
    this.controllerFactory,
    this.initializeController = true,
  });

  /// Test and acceptance seam for exercising the real application shell with
  /// a bounded backend. Production callers omit this and always use the
  /// platform-backed [ClientController].
  final ClientController Function()? controllerFactory;

  /// Acceptance controllers may be fully staged before the first frame. The
  /// production entry point keeps the default and performs normal bootstrap.
  final bool initializeController;

  @override
  State<LicoApp> createState() => _LicoAppState();
}

class _LicoAppState extends State<LicoApp> with WidgetsBindingObserver {
  late final ClientController _controller;
  int? _viewId;

  @override
  void initState() {
    super.initState();
    AgentRenderAdapterRegistry.instance = AgentRenderAdapterRegistry(
      jsonSource: DefaultAgentRenderAdapterJsonSource(),
    );
    _controller = widget.controllerFactory?.call() ?? ClientController();
    WidgetsBinding.instance.addObserver(this);
    _controller.updateConversationAttention(
      lifecycleState:
          WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed,
    );
    if (widget.initializeController) {
      unawaited(_controller.initialize());
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        unawaited(_controller.initializeLlmGateway());
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
    _controller.updateConversationAttention(lifecycleState: state);
  }

  @override
  void didChangeViewFocus(ViewFocusEvent event) {
    if (_viewId != null && event.viewId != _viewId) {
      return;
    }
    _controller.updateConversationAttention(
      viewFocused: event.state == ViewFocusState.focused,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: _controller.appPresentationListenable,
      builder: (context, _, _) {
        final presetId = _controller.appearancePresetId;
        final presets = _controller.appearancePresetConfigs;
        return MaterialApp(
          onGenerateTitle: (context) => LicoStrings.of(context).appTitle,
          debugShowCheckedModeBanner: false,
          supportedLocales: LicoStrings.supportedLocales,
          locale: LicoStrings.localeForPreference(_controller.localePreference),
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
          home: ClientShell(controller: _controller),
        );
      },
    );
  }
}
