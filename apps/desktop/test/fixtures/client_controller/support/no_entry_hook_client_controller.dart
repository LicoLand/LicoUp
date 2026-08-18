import 'package:licoup/src/application/controller/client_controller.dart';
import 'package:licoup/src/application/features/navigation/controller/client_interface_entry_hook_controller.dart';
import 'package:licoup/src/contracts/presentation/semantic_destination.dart';

/// Test seam: keeps every interface-entry Hook lane out of hermetic scenarios
/// that assert exact gateway call counts or status lines.
final class NoEntryHookClientController extends ClientController {
  NoEntryHookClientController({
    super.portableData,
    super.agentService,
    super.mobileRelayService,
  });

  @override
  Map<ClientSection, ClientInterfaceEntryHookTask>
  resolveInterfaceEntryHookTasks() => const {};
}
