import 'dart:async';
import 'dart:ui' show ViewFocusEvent, ViewFocusState;

import 'package:flutter/material.dart';
import 'package:file_selector/file_selector.dart';
import 'package:licoup/src/frontend/appearance/loading_effect_catalog.dart';
import 'package:licoup/src/frontend/shared/ui/lico_loading_effect.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'src/composition/client_app_composition.dart';
import 'src/presentation/settings/settings_effect.dart';
import 'src/platform/native_client/agent_service.dart';
import 'src/frontend/binding/projection_builder.dart';
import 'src/frontend/binding/projection_telemetry_scope.dart';
import 'src/frontend/environment/environment_projection_adapter.dart';
import 'src/frontend/l10n/lico_strings.dart';
import 'src/frontend/appearance/appearance_preset_config.dart';
import 'src/frontend/appearance/appearance_projection_adapter.dart';
import 'src/frontend/shared/ui/glass_lens.dart';
import 'src/frontend/shared/ui/theme.dart';
import 'src/frontend/shared/ui/lico_motion_scope.dart';
import 'src/frontend/shell/client_shell.dart';
import 'src/frontend/binding/shell_renderer_port.dart';
import 'src/presentation/appearance/appearance_projection.dart';
import 'src/presentation/environment/environment_projection.dart';
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
  late ClientAppComposition _composition;
  StreamSubscription<SettingsEffect>? _settingsEffects;
  int? _viewId;
  var _dataHomeRelocating = false;
  var _dataHomeRecoveryRequired = false;
  var _dataHomePhase = 'preparing';
  var _dataHomeOperation = 'move';
  String? _dataHomeFailure;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(GlassLens.ensureLoaded());
    _replaceComposition(initialize: widget.initializeController);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _viewId = View.of(context).viewId;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_dataHomeRelocating) return;
    _composition.updateConversationAttention(lifecycleState: state);
  }

  @override
  void didChangeViewFocus(ViewFocusEvent event) {
    if (_dataHomeRelocating || (_viewId != null && event.viewId != _viewId)) {
      return;
    }
    _composition.updateConversationAttention(
      viewFocused: event.state == ViewFocusState.focused,
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_settingsEffects?.cancel());
    unawaited(_composition.dispose());
    super.dispose();
  }

  ClientAppComposition _replaceComposition({required bool initialize}) {
    final composition =
        widget.compositionFactory?.call() ?? ClientAppComposition();
    _composition = composition;
    composition.attachFlutterObservation(WidgetsBinding.instance);
    _settingsEffects = composition.settings.effects.effects.listen((effect) {
      if (effect is DataHomeRelocationRequested) {
        unawaited(_relocateDataHome(effect.destinationParent));
      } else if (effect is PreviousDataHomeCleanupRequested) {
        unawaited(_cleanupPreviousDataHome(effect.expectedPreviousRootPath));
      }
    });
    composition.updateConversationAttention(
      lifecycleState:
          WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed,
    );
    if (initialize) _initializeComposition(composition);
    return composition;
  }

  void _initializeComposition(ClientAppComposition composition) {
    final initialization = composition.initialize();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // A visible window does not mean Local's startup reads have finished.
      // Gateway startup shares the native command queue, so it must not
      // overtake Local-first bootstrap.
      unawaited(
        initialization.then<void>((_) async {
          if (!mounted ||
              _dataHomeRelocating ||
              !identical(_composition, composition)) {
            return;
          }
          var needsRecovery = false;
          try {
            needsRecovery = await composition.needsDataHomeRecovery;
          } on Object {
            needsRecovery = false;
          }
          if (!mounted ||
              _dataHomeRelocating ||
              !identical(_composition, composition)) {
            return;
          }
          if (needsRecovery) {
            setState(() => _dataHomeRecoveryRequired = true);
            return;
          }
          if (composition.bootstrapFailed) return;
          await composition.initializeLlmGateway();
        }),
      );
    });
  }

  Future<void> _relocateDataHome(String destinationParent) async {
    if (_dataHomeRelocating || !mounted) return;
    final previous = _composition;
    setState(() {
      _dataHomeRelocating = true;
      _dataHomePhase = 'stopping-writers';
      _dataHomeOperation = 'move';
      _dataHomeFailure = null;
    });
    unawaited(_settingsEffects?.cancel());

    Object? failure;
    try {
      await previous.relocateDataHome(
        destinationParent,
        onPhase: (phase) {
          if (mounted) setState(() => _dataHomePhase = phase);
        },
      );
    } on Object catch (error) {
      failure = error;
    }

    if (!mounted) return;
    final rebuilt = _replaceComposition(initialize: false);
    setState(() {
      _dataHomeRelocating = false;
      _dataHomePhase = 'complete';
      _dataHomeFailure = failure == null ? null : _dataHomeFailureCode(failure);
    });
    if (widget.initializeController) _initializeComposition(rebuilt);
  }

  Future<void> _cleanupPreviousDataHome(String expectedPreviousRootPath) async {
    if (_dataHomeRelocating || !mounted) return;
    final previous = _composition;
    setState(() {
      _dataHomeRelocating = true;
      _dataHomePhase = 'stopping-writers';
      _dataHomeOperation = 'cleanup';
      _dataHomeFailure = null;
    });
    unawaited(_settingsEffects?.cancel());

    Object? failure;
    try {
      await previous.cleanupPreviousDataHome(
        expectedPreviousRootPath,
        onPhase: (phase) {
          if (mounted) setState(() => _dataHomePhase = phase);
        },
      );
    } on Object catch (error) {
      failure = error;
    }

    if (!mounted) return;
    final rebuilt = _replaceComposition(initialize: false);
    setState(() {
      _dataHomeRelocating = false;
      _dataHomePhase = 'complete';
      _dataHomeFailure = failure == null ? null : _dataHomeFailureCode(failure);
    });
    if (widget.initializeController) _initializeComposition(rebuilt);
  }

  void _retryMissingDataHome() {
    if (_dataHomeRelocating || !mounted) return;
    setState(() {
      _dataHomeRecoveryRequired = false;
      _dataHomeFailure = null;
    });
    _initializeComposition(_composition);
  }

  Future<void> _chooseDataHomeRecovery(BuildContext context) async {
    if (_dataHomeRelocating || !mounted) return;
    final strings = LicoStrings.of(context);
    final selected = await getDirectoryPath(
      confirmButtonText: strings.chooseExistingDataHome,
    );
    if (selected == null || !mounted || !context.mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(strings.confirmDataHomeRecovery),
        content: Text(strings.dataHomeRecoveryConfirmation),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: Text(strings.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: Text(strings.useThisFolder),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    final previous = _composition;
    setState(() {
      _dataHomeRelocating = true;
      _dataHomePhase = 'recovering-root';
      _dataHomeOperation = 'recovery';
      _dataHomeFailure = null;
    });
    unawaited(_settingsEffects?.cancel());
    Object? failure;
    try {
      await previous.recoverDataHome(
        selected,
        onPhase: (phase) {
          if (mounted) setState(() => _dataHomePhase = phase);
        },
      );
    } on Object catch (error) {
      failure = error;
    }

    if (!mounted) return;
    final rebuilt = _replaceComposition(initialize: false);
    setState(() {
      _dataHomeRelocating = false;
      _dataHomeRecoveryRequired = false;
      _dataHomePhase = 'complete';
      _dataHomeFailure = failure == null ? null : _dataHomeFailureCode(failure);
    });
    if (widget.initializeController) _initializeComposition(rebuilt);
  }

  String _dataHomeFailureCode(Object error) => switch (error) {
    LicoClientRpcException(:final code) => code,
    _ => 'data_home_operation_failed',
  };

  @override
  Widget build(BuildContext context) {
    if (_dataHomeRelocating) {
      return _DataHomeRelocationProgress(
        phase: _dataHomePhase,
        operation: _dataHomeOperation,
      );
    }
    if (_dataHomeRecoveryRequired) {
      return _MissingDataHomeRecovery(
        failureCode: _dataHomeFailure,
        onRetry: _retryMissingDataHome,
        onChoose: _chooseDataHomeRecovery,
      );
    }
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
            builder: (context, child) => Column(
              children: [
                if (_dataHomeFailure != null)
                  MaterialBanner(
                    content: Text(
                      LicoStrings.of(context).dataHomeOperationFailed(
                        _dataHomeOperation,
                        _dataHomeFailure!,
                      ),
                    ),
                    actions: [
                      TextButton(
                        onPressed: () =>
                            setState(() => _dataHomeFailure = null),
                        child: Text(LicoStrings.of(context).dismiss),
                      ),
                    ],
                  ),
                Expanded(
                  child: ProjectionBuilder<EnvironmentProjection, bool>(
                    source: _composition.binding.environment,
                    select: _systemReduceMotion,
                    builder: (context, systemReduceMotion) => LicoMotionScope(
                      reduceMotion: appearance.reduceMotion,
                      systemReduceMotion: systemReduceMotion,
                      child: LicoLoadingEffectScope(
                        effect: loadingEffectForId(appearance.loadingEffectId),
                        child: child ?? const SizedBox.shrink(),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            // Theme changes are atomic visual updates; this also prevents the
            // MaterialApp-owned AnimatedTheme from outrunning the motion scope.
            themeAnimationDuration: Duration.zero,
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
    final scoped = ProviderScope(
      overrides: _composition.presentationOverrides,
      child: app,
    );
    return telemetry == null
        ? scoped
        : ProjectionTelemetryScope(observer: telemetry, child: scoped);
  }
}

AppearanceProjection _appearanceProjection(AppearanceProjection value) => value;

LocaleProjection _localeProjection(LocaleProjection value) => value;

bool _systemReduceMotion(EnvironmentProjection value) =>
    value.systemReduceMotion;

final class _DataHomeRelocationProgress extends StatelessWidget {
  const _DataHomeRelocationProgress({
    required this.phase,
    required this.operation,
  });

  final String phase;
  final String operation;

  @override
  Widget build(BuildContext context) => MaterialApp(
    supportedLocales: LicoStrings.supportedLocales,
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
    ],
    home: Builder(
      builder: (context) {
        final strings = LicoStrings.of(context);
        final label = strings.dataHomeMovePhase(phase);
        return Scaffold(
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 420),
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(Icons.drive_file_move_outline, size: 42),
                    const SizedBox(height: 20),
                    Text(
                      strings.dataHomeOperationTitle(operation),
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 18),
                    Semantics(
                      liveRegion: true,
                      label: label,
                      child: Text(label, textAlign: TextAlign.center),
                    ),
                    const SizedBox(height: 20),
                    const LinearProgressIndicator(),
                    const SizedBox(height: 16),
                    Text(
                      strings.dataHomeMoveSourcePreserved,
                      textAlign: TextAlign.center,
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    ),
  );
}

final class _MissingDataHomeRecovery extends StatelessWidget {
  const _MissingDataHomeRecovery({
    required this.failureCode,
    required this.onRetry,
    required this.onChoose,
  });

  final String? failureCode;
  final VoidCallback onRetry;
  final Future<void> Function(BuildContext context) onChoose;

  @override
  Widget build(BuildContext context) => MaterialApp(
    supportedLocales: LicoStrings.supportedLocales,
    localizationsDelegates: const [
      GlobalMaterialLocalizations.delegate,
      GlobalCupertinoLocalizations.delegate,
      GlobalWidgetsLocalizations.delegate,
    ],
    home: Builder(
      builder: (context) {
        final strings = LicoStrings.of(context);
        return Scaffold(
          body: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const Icon(Icons.folder_off_outlined, size: 42),
                    const SizedBox(height: 20),
                    Text(
                      strings.dataHomeRecoveryTitle,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.titleLarge,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      strings.dataHomeRecoveryDescription,
                      textAlign: TextAlign.center,
                    ),
                    if (failureCode != null) ...[
                      const SizedBox(height: 16),
                      Text(
                        strings.dataHomeRecoveryFailed(failureCode!),
                        textAlign: TextAlign.center,
                      ),
                    ],
                    const SizedBox(height: 24),
                    FilledButton.icon(
                      key: const Key('data-home-recovery-choose'),
                      onPressed: () => unawaited(onChoose(context)),
                      icon: const Icon(Icons.folder_open_outlined),
                      label: Text(strings.chooseExistingDataHome),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton(
                      key: const Key('data-home-recovery-retry'),
                      onPressed: onRetry,
                      child: Text(strings.retry),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    ),
  );
}
