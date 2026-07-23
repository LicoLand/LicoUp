import 'package:flutter_client/src/application/controller/client_controller.dart';
import 'package:flutter_client/src/contracts/presentation/semantic_destination.dart';

/// Test seam: keeps the background section preload out of hermetic scenarios
/// that assert exact gateway call counts or status lines.
final class NoPreloadClientController extends ClientController {
  NoPreloadClientController({
    super.portableData,
    super.agentService,
    super.mobileRelayService,
  });

  @override
  Map<ClientSection, Future<void> Function()> resolveSectionPreloadTasks() =>
      const {};
}
