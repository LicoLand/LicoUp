import 'package:flutter/material.dart';

import 'package:licoup/src/contracts/presentation/layout_environment.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';
import 'package:licoup/src/frontend/binding/effect_listener.dart';
import 'package:licoup/src/frontend/binding/projection_builder.dart';
import 'package:licoup/src/frontend/binding/shell_renderer_port.dart';
import 'package:licoup/src/frontend/l10n/lico_strings.dart';
import 'package:licoup/src/frontend/layout/layout_chrome_features.dart';
import 'package:licoup/src/frontend/layout/layout_focus_coordinator.dart';
import 'package:licoup/src/frontend/layout/layout_host.dart';
import 'package:licoup/src/frontend/layout/layout_surface_bundle.dart';
import 'package:licoup/src/frontend/shell/client_platform.dart';
import 'package:licoup/src/frontend/shell/layout_palette_projection.dart';
import 'package:licoup/src/frontend/shared/ui/theme.dart';
import 'package:licoup/src/presentation/shell/shell_binding.dart';
import 'package:licoup/src/presentation/shell/shell_effect.dart';
import 'package:licoup/src/presentation/shell/shell_intent.dart';
import 'package:licoup/src/presentation/shell/shell_projection.dart';

class ClientShell extends StatefulWidget {
  const ClientShell({super.key, required this.binding, required this.renderer});

  final ShellBinding binding;
  final ShellRendererPort renderer;

  @override
  State<ClientShell> createState() => _ClientShellState();
}

class _ClientShellState extends State<ClientShell>
    implements LayoutDestinationContentPort {
  late GlobalKey _agentsHomeKey;
  final LayoutFocusCoordinator _focusCoordinator = LayoutFocusCoordinator();
  final ValueNotifier<bool> _auxChromePanelOpen = ValueNotifier<bool>(false);
  late LayoutChromeFeatures _chromeFeatures;

  @override
  void initState() {
    super.initState();
    _agentsHomeKey = widget.renderer.createAgentsHomeKey();
    _chromeFeatures = widget.renderer.createChromeFeatures(_auxChromePanelOpen);
  }

  @override
  void didUpdateWidget(ClientShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.renderer, widget.renderer)) {
      _agentsHomeKey = widget.renderer.createAgentsHomeKey();
      _chromeFeatures = widget.renderer.createChromeFeatures(
        _auxChromePanelOpen,
      );
    }
  }

  @override
  void dispose() {
    _auxChromePanelOpen.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      body: EffectListener<ShellEffect>(
        source: widget.binding.effects,
        onEffect: _handleEffect,
        child: ProjectionBuilder<ShellProjection, ShellEnvironment>(
          source: widget.binding.projection,
          select: (projection) => projection.environment,
          builder: (context, shellEnvironment) => LayoutBuilder(
            builder: (context, constraints) {
              final environment = _environmentFor(
                context,
                constraints,
                shellEnvironment.mobileSurface,
              );
              widget.binding.intents.send(
                UpdateShellLayoutEnvironment(environment),
              );
              return ProjectionBuilder<ShellProjection, _ShellRenderSlice>(
                source: widget.binding.projection,
                select: _ShellRenderSlice.fromProjection,
                builder: (context, slice) =>
                    _buildLayoutHost(context, environment, slice),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _buildLayoutHost(
    BuildContext context,
    LayoutEnvironment environment,
    _ShellRenderSlice slice,
  ) {
    final colors = context.licoColors;
    return LayoutChromeFeaturesScope(
      features: _chromeFeatures,
      child: LayoutHost(
        selection: slice.layout.selection,
        registry: widget.renderer.layoutRegistry,
        stateStore: widget.renderer.layoutStateStore,
        environment: environment,
        onUpdateEnvironment: (value) =>
            widget.binding.intents.send(UpdateShellLayoutEnvironment(value)),
        destination: slice.destination,
        onSelectDestination: (destination) =>
            widget.binding.intents.send(SelectShellDestination(destination)),
        destinationLabel: (destination) =>
            _destinationLabel(LicoStrings.of(context), destination),
        content: this,
        focusCoordinator: _focusCoordinator,
        primaryFocusTarget: LayoutFocusTargets.primaryLandmark,
        loadingBuilder: (_) => const Center(child: CircularProgressIndicator()),
        palette: layoutPaletteFromColors(colors),
        chrome: widget.renderer.chrome,
      ),
    );
  }

  LayoutEnvironment _environmentFor(
    BuildContext context,
    BoxConstraints constraints,
    bool runtimeMobileSurface,
  ) {
    final media = MediaQuery.of(context);
    final mobile = runtimeMobileSurface || isMobileClientPlatform(context);
    return LayoutEnvironment.fromConstraints(
      surface: mobile
          ? LayoutRuntimeSurface.mobile
          : LayoutRuntimeSurface.desktop,
      width: constraints.maxWidth,
      height: constraints.maxHeight,
      textScale: media.textScaler.scale(1),
      safeInsets: LayoutInsets(
        left: media.padding.left,
        top: media.padding.top,
        right: media.padding.right,
        bottom: media.padding.bottom,
      ),
      keyboardInset: media.viewInsets.bottom,
      hasPointer: !mobile,
      hasKeyboard: !mobile,
      hasTouch: mobile,
      reducedMotion: media.disableAnimations,
    );
  }

  void _handleEffect(ShellEffect effect) {
    if (effect case ShellDestinationReselected(
      destination: ClientSection.agents,
    )) {
      widget.renderer.resetAgentsHome(_agentsHomeKey);
    }
  }

  @override
  Widget buildDestination(BuildContext context, ClientSection destination) =>
      widget.renderer.buildDestination(
        context,
        destination,
        agentsHomeKey: _agentsHomeKey,
      );

  String _destinationLabel(LicoStrings strings, ClientSection section) =>
      switch (section) {
        ClientSection.agents => strings.agents,
        ClientSection.monitoring => strings.tokenUsage,
        ClientSection.skillHub => strings.skillHub,
        ClientSection.pluginManagement => strings.pluginManagement,
        ClientSection.mobileRelay => strings.mobileRelay,
        ClientSection.models => strings.modelGateway,
        ClientSection.settings => strings.settings,
        ClientSection.agentHub => strings.agentHub,
      };
}

final class _ShellRenderSlice {
  const _ShellRenderSlice({required this.layout, required this.destination});

  factory _ShellRenderSlice.fromProjection(ShellProjection projection) =>
      _ShellRenderSlice(
        layout: projection.layout,
        destination: projection.destination,
      );

  final ShellLayout layout;
  final ClientSection destination;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _ShellRenderSlice &&
          other.layout == layout &&
          other.destination == destination;

  @override
  int get hashCode => Object.hash(layout, destination);
}
