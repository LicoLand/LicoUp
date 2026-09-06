import 'package:licoup/src/application/state/application_signal.dart';

import 'package:licoup/src/application/controller/assembly/client_component_assembly_contracts.dart';
import 'package:licoup/src/application/features/targets/controller/target_controller.dart';
import 'package:licoup/src/platform/agents/agent_tab_order_store.dart';
import 'package:licoup/src/platform/agents/scanned_targets_cache_store.dart';
import 'package:licoup/src/platform/native_client/agent_service.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';

final class ClientTargetComponentAssembly {
  ClientTargetComponentAssembly({
    required PortableDataRoot portableData,
    required AgentService agentService,
    required AgentTabOrderStore agentTabOrderStore,
    required ScannedTargetsCacheStore scannedTargetsCacheStore,
    required bool Function() isMobileRuntime,
    required Future<List<TargetCandidate>> Function({
      Map<String, dynamic>? pairingStatus,
    })
    discoverMobileTargets,
    required ApplicationCallback onTargetsSettled,
    required Future<void> Function(String) loadSelectedConversation,
    required String Function() selectedAgentId,
    required bool Function() shouldLoadSelectedConversation,
    required ClientComponentStatusSink reportStatus,
  }) : controller = TargetController(
         gateway: agentService,
         snapshotRepository: scannedTargetsCacheStore,
         tabOrderRepository: agentTabOrderStore,
         portableData: portableData,
         packagedTargetIds: AgentService.packagedScanTargetIds,
         isMobileRuntime: isMobileRuntime,
         scanMobileTargets: discoverMobileTargets,
         onTargetsSettled: onTargetsSettled,
         loadSelectedConversation: () =>
             loadSelectedConversation(selectedAgentId()),
         shouldLoadSelectedConversation: shouldLoadSelectedConversation,
         onStatus: (update) => reportStatus(
           chinese: update.chinese,
           english: update.english,
           caption: update.caption,
           errorCode: update.errorCode,
         ),
       );

  final TargetController controller;

  void dispose() => controller.dispose();
}
