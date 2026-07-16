import 'package:flutter/foundation.dart' show ChangeNotifier;

import 'package:flutter_client/src/application/composition/agent_usage_gateway_adapter.dart';
import 'package:flutter_client/src/application/controller/assembly/client_component_assembly_contracts.dart';
import 'package:flutter_client/src/application/features/agents/controller/agent_usage_controller.dart';
import 'package:flutter_client/src/backend/features/agents/services/agent_usage_service.dart';
import 'package:flutter_client/src/platform/native_client/agent_service.dart';

final class ClientUsageComponentAssembly {
  ClientUsageComponentAssembly({
    required AgentUsageService agentUsageService,
    required AgentService agentService,
    required String Function() selectedAgentId,
    required ClientComponentStatusSink reportStatus,
  }) : controller = AgentUsageController(
         gateway: AgentUsageGatewayAdapter(
           service: agentUsageService,
           runner: agentService,
         ),
         selectedAgentId: selectedAgentId,
         onStatus:
             ({
               required chinese,
               required english,
               required caption,
               errorCode = '',
             }) => reportStatus(
               chinese: chinese,
               english: english,
               caption: caption,
               errorCode: errorCode,
             ),
       );

  final AgentUsageController controller;

  Iterable<ChangeNotifier> get listenables => [controller];

  void dispose() => controller.dispose();
}
