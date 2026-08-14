import 'package:flutter/material.dart';

import 'package:licoup/src/application/features/settings/controller/agent_resource_usage_controller.dart';
import 'package:licoup/src/application/features/settings/controller/client_resource_usage_controller.dart';
import 'package:licoup/src/application/features/settings/contracts/agent_resource_usage_gateway.dart';
import 'package:licoup/src/frontend/features/settings/ui/client_resource_usage_card.dart';

/// Owns the live client and agent memory samplers for the Diagnostics ring.
class DiagnosticsResourceSection extends StatefulWidget {
  const DiagnosticsResourceSection({
    super.key,
    required this.gateway,
    this.clientController,
    this.agentController,
  });

  final AgentResourceUsageGateway gateway;

  /// Injectable for tests.
  final ClientResourceUsageController? clientController;

  /// Injectable for tests.
  final AgentResourceUsageController? agentController;

  @override
  State<DiagnosticsResourceSection> createState() =>
      _DiagnosticsResourceSectionState();
}

class _DiagnosticsResourceSectionState
    extends State<DiagnosticsResourceSection> {
  ClientResourceUsageController? _ownedClient;
  AgentResourceUsageController? _ownedAgent;

  ClientResourceUsageController get _client =>
      widget.clientController ??
      (_ownedClient ??= createClientResourceUsageController());

  AgentResourceUsageController get _agent =>
      widget.agentController ??
      (_ownedAgent ??= AgentResourceUsageController(gateway: widget.gateway));

  @override
  void dispose() {
    _ownedClient?.dispose();
    _ownedAgent?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ClientResourceUsageCard(
      controller: _client,
      agentController: _agent,
    );
  }
}
