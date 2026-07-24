import 'package:flutter/foundation.dart' show ChangeNotifier;

import 'package:licoup/src/application/composition/mobile_home_layout_repository_adapter.dart';
import 'package:licoup/src/application/composition/mobile_relay_gateway_adapter.dart';
import 'package:licoup/src/application/controller/assembly/client_component_assembly_contracts.dart';
import 'package:licoup/src/application/features/mobile_relay/controller/mobile_home_layout_controller.dart';
import 'package:licoup/src/application/features/mobile_relay/controller/mobile_relay_controller.dart';
import 'package:licoup/src/application/features/mobile_relay/controller/secure_mesh_controller.dart';
import 'package:licoup/src/backend/features/mobile_relay/services/mobile_home_layout_service.dart';
import 'package:licoup/src/contracts/mobile_home_layout_repository.dart';
import 'package:licoup/src/contracts/mobile_relay_control.dart';
import 'package:licoup/src/contracts/skill_hub.dart';
import 'package:licoup/src/platform/client_clipboard_service.dart';
import 'package:licoup/src/platform/mobile_relay/mobile_relay_service.dart';
import 'package:licoup/src/platform/native_client/agent_service.dart';
import 'package:licoup/src/platform/runtime_platform_bridge.dart';
import 'package:licoup/src/platform/secure_mesh/secure_mesh_capability_service.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';

final class ClientMobileComponentAssembly {
  ClientMobileComponentAssembly({
    required PortableDataRoot portableData,
    required AgentService agentService,
    required MobileRelayService mobileRelayService,
    required SecureMeshCapabilityService secureMeshCapabilityService,
    required MobileHomeLayoutService mobileHomeLayoutService,
    required ClientClipboardService clientClipboardService,
    required RuntimePlatformBridge runtimePlatformBridge,
    required SkillHubGateway skillHubGateway,
    required void Function(Map<String, dynamic>?) replaceSkillInstallResult,
    required bool Function() isMobileRuntime,
    required List<TargetCandidate> Function() scannedTargets,
    required void Function(List<TargetCandidate>) replaceScannedTargets,
    required Future<void> Function() ensureTargetsSilently,
    required Future<List<TargetCandidate>> Function({
      Map<String, dynamic>? pairingStatus,
    })
    discoverMobileTargets,
    required void Function() selectDefaultConversationAgent,
    required ClientComponentStatusSink reportStatus,
    MobileHomeLayoutRepository? mobileHomeLayoutRepository,
  }) : homeLayoutController = MobileHomeLayoutController(
         repository:
             mobileHomeLayoutRepository ??
             MobileHomeLayoutRepositoryAdapter(
               service: mobileHomeLayoutService,
               portableData: portableData,
             ),
       ) {
    final relayGateway = MobileRelayGatewayAdapter(
      relayService: mobileRelayService,
      agentService: agentService,
      capabilityService: secureMeshCapabilityService,
    );
    final operationGate = MobileRelayOperationGate();
    relayController = MobileRelayController(
      gateway: relayGateway,
      operationGate: operationGate,
      isMobileRuntime: isMobileRuntime,
      isAndroid: () => runtimePlatformBridge.isAndroid,
      isIos: () => runtimePlatformBridge.isIos,
      writeClipboard: clientClipboardService.writeText,
      onStatus: (update) => reportStatus(
        chinese: update.chinese,
        english: update.english,
        caption: update.caption,
        errorCode: update.errorCode,
      ),
      ensureTargets: () async {
        if (scannedTargets().isEmpty) await ensureTargetsSilently();
      },
      discoverTargets: (pairingStatus) async {
        replaceScannedTargets(
          await discoverMobileTargets(pairingStatus: pairingStatus),
        );
        selectDefaultConversationAgent();
      },
    );
    secureMeshController = SecureMeshController(
      gateway: relayGateway,
      skillInstaller: SecureMeshSkillInstallGatewayAdapter(skillHubGateway),
      operationGate: operationGate,
      onStatus: (update) => reportStatus(
        chinese: update.chinese,
        english: update.english,
        caption: update.caption,
        errorCode: update.errorCode,
      ),
      onSkillInstallResult: replaceSkillInstallResult,
    );
  }

  final MobileHomeLayoutController homeLayoutController;
  late final MobileRelayController relayController;
  late final SecureMeshController secureMeshController;

  Iterable<ChangeNotifier> get listenables => [
    homeLayoutController,
    relayController,
    secureMeshController,
  ];

  void dispose() {
    secureMeshController.dispose();
    relayController.dispose();
    homeLayoutController.dispose();
  }
}
