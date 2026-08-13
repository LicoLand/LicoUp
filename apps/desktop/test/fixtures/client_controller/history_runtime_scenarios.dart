import 'history_runtime/message_dispatch_scenarios.dart';
import 'history_runtime/session_selection_scenarios.dart';
import 'history_runtime/streaming_projection_scenarios.dart';
import 'history_runtime/streaming_readback_scenarios.dart';

void registerClientHistoryRuntimeScenarios() {
  registerClientHistoryRuntimeMessageDispatchScenarios();
  registerClientHistoryRuntimeSessionSelectionScenarios();
  registerClientHistoryRuntimeStreamingProjectionScenarios();
  registerClientHistoryRuntimeStreamingReadbackScenarios();
}
