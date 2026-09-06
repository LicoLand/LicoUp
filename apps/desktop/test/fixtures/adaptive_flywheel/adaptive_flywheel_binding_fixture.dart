import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/composition/features/agents/agents_feature_composition.dart';
import 'package:licoup/src/composition/features/conversation/conversation_feature_composition.dart';
import 'package:licoup/src/presentation/agents/agents_binding.dart';
import 'package:licoup/src/presentation/conversation/conversation_binding.dart';

/// Test-only composition seam that keeps widgets on semantic bindings while
/// retaining the real application adapters and fake native runner beneath.
final class AdaptiveFlywheelBindingFixture {
  AdaptiveFlywheelBindingFixture(ClientController controller)
    : _agents = AgentsFeatureComposition(controller),
      _conversation = ConversationFeatureComposition(controller);

  final AgentsFeatureComposition _agents;
  final ConversationFeatureComposition _conversation;

  AgentsBinding get agents => _agents.binding;
  ConversationBinding get conversation => _conversation.binding;

  Future<void> close() async {
    await _conversation.close();
    await _agents.close();
  }
}
