import 'package:flutter_client/src/application/composition/agent_conversation_gateway_adapter.dart';
import 'package:flutter_client/src/application/features/agents/contracts/agent_conversation_gateway.dart';
import 'package:flutter_client/src/application/features/agents/conversation/conversation_presentation_signals.dart';
import 'package:flutter_client/src/backend/features/agents/services/agent_conversation_service.dart';
import 'package:flutter_client/src/platform/mobile_relay/mobile_relay_service.dart';
import 'package:flutter_client/src/platform/native_client/agent_service.dart';

final class ClientConversationComponentAssembly {
  ClientConversationComponentAssembly({
    required AgentConversationService conversationService,
    required MobileRelayService mobileRelayService,
    required AgentService agentService,
  }) : conversationGateway = AgentConversationGatewayAdapter(
         service: conversationService,
         runner: agentService,
       ),
       mobileConversationGateway = MobileAgentConversationGatewayAdapter(
         service: mobileRelayService,
         agentService: agentService,
       );

  final ConversationPresentationSignals presentationSignals =
      ConversationPresentationSignals();
  final AgentConversationGateway conversationGateway;
  final MobileAgentConversationGateway mobileConversationGateway;

  void dispose() => presentationSignals.dispose();
}
