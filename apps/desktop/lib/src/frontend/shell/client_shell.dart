import 'package:flutter/material.dart';

import 'package:flutter_client/src/application/controller/client_controller.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';
import 'package:flutter_client/src/contracts/presentation/layout_environment.dart';
import 'package:flutter_client/src/frontend/l10n/lico_strings.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agent_usage_panel.dart';
import 'package:flutter_client/src/frontend/features/agents/ui/agents_canvas.dart';
import 'package:flutter_client/src/frontend/shell/client_platform.dart';
import 'package:flutter_client/src/frontend/layout/layout_focus_coordinator.dart';
import 'package:flutter_client/src/frontend/layout/layout_host.dart';
import 'package:flutter_client/src/frontend/layout/layout_palette.dart';
import 'package:flutter_client/src/frontend/layout/layout_surface_bundle.dart';
import 'package:flutter_client/src/frontend/features/skill_hub/ui/skill_hub_panel.dart';
import 'package:flutter_client/src/frontend/features/mobile_relay/ui/mobile_agents_home.dart';
import 'package:flutter_client/src/frontend/features/mobile_relay/ui/mobile_relay_panel.dart';
import 'package:flutter_client/src/frontend/features/settings/ui/settings_panel.dart';
import 'package:flutter_client/src/frontend/features/plugin_management/ui/adapter_plugin_panel.dart';
import 'package:flutter_client/src/frontend/shell/client_layout_chrome_adapter.dart';
import 'package:flutter_client/src/frontend/shared/ui/theme.dart';

class ClientShell extends StatefulWidget {
  const ClientShell({super.key, required this.controller});

  final ClientController controller;

  @override
  State<ClientShell> createState() => _ClientShellState();
}

class _ClientShellState extends State<ClientShell>
    implements LayoutDestinationContentPort {
  ClientController get controller => widget.controller;
  final _agentsHomeKey = GlobalKey<MobileAgentsHomeState>();
  final _focusCoordinator = LayoutFocusCoordinator();
  late ClientLayoutChromeAdapter _layoutChromeAdapter;

  @override
  void initState() {
    super.initState();
    _layoutChromeAdapter = ClientLayoutChromeAdapter(controller);
  }

  @override
  void didUpdateWidget(ClientShell oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, controller)) {
      _layoutChromeAdapter.dispose();
      _layoutChromeAdapter = ClientLayoutChromeAdapter(controller);
    }
  }

  @override
  void dispose() {
    _layoutChromeAdapter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        return Scaffold(body: LayoutBuilder(builder: _buildLayoutHost));
      },
    );
  }

  Widget _buildLayoutHost(BuildContext context, BoxConstraints constraints) {
    final media = MediaQuery.of(context);
    final colors = context.licoColors;
    final mobile = _isMobileShell(context);
    final section = _effectiveSection(context);
    final environment = LayoutEnvironment.fromConstraints(
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
    return LayoutHost(
      manager: controller.layoutManager,
      registry: controller.layoutComposition.registry,
      stateStore: controller.layoutComposition.stateStore,
      environment: environment,
      destination: section,
      onSelectDestination: _selectDestination,
      destinationLabel: (destination) =>
          _destinationLabel(LicoStrings.of(context), destination),
      content: this,
      focusCoordinator: _focusCoordinator,
      primaryFocusTarget: LayoutFocusTargets.primaryLandmark,
      loadingBuilder: (_) => const Center(child: CircularProgressIndicator()),
      palette: LayoutPalette(
        background: colors.background,
        surface: colors.surface,
        surfaceLow: colors.surfaceLow,
        surfaceHigh: colors.surfaceHigh,
        surfaceHighest: colors.surfaceHighest,
        line: colors.line,
        text: colors.text,
        textMuted: colors.textMuted,
        primary: colors.primary,
        primaryStrong: colors.primaryStrong,
        primaryFixed: colors.primaryFixed,
        textOnPrimary: colors.textOnPrimary,
        info: colors.info,
        infoMuted: colors.infoMuted,
        success: colors.success,
        warning: colors.warning,
        error: colors.error,
      ),
      chrome: _layoutChromeAdapter,
    );
  }

  @override
  Widget buildDestination(BuildContext context, ClientSection destination) {
    return switch (destination) {
      ClientSection.agents => AgentsCanvas(
        controller: controller,
        agentsHomeKey: _agentsHomeKey,
      ),
      ClientSection.monitoring => AgentUsagePanel(controller: controller),
      ClientSection.skillHub => SkillHubPanel(controller: controller),
      ClientSection.pluginManagement => AdapterPluginPanel(
        controller: controller,
      ),
      ClientSection.mobileRelay => MobileRelayPanel(controller: controller),
      ClientSection.settings => SettingsPanel(controller: controller),
    };
  }

  ClientSection _effectiveSection(BuildContext context) {
    final section = controller.currentSection;
    if (!_isMobileShell(context)) {
      return section;
    }
    return switch (section) {
      ClientSection.agents || ClientSection.settings => section,
      _ => ClientSection.agents,
    };
  }

  bool _isMobileShell(BuildContext context) {
    return controller.mobileClientRuntimePlatform ||
        isMobileClientPlatform(context);
  }

  void _selectDestination(ClientSection destination) {
    if (destination == ClientSection.agents &&
        controller.currentSection == ClientSection.agents) {
      _agentsHomeKey.currentState?.resetToList();
    }
    controller.selectSection(destination);
  }

  String _destinationLabel(LicoStrings strings, ClientSection section) =>
      switch (section) {
        ClientSection.agents => strings.agents,
        ClientSection.monitoring => strings.tokenUsage,
        ClientSection.skillHub => strings.skillHub,
        ClientSection.pluginManagement => strings.pluginManagement,
        ClientSection.mobileRelay => strings.mobileRelay,
        ClientSection.settings => strings.settings,
      };
}
