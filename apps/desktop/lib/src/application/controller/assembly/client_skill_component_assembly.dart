import 'package:licoup/src/application/controller/assembly/client_component_assembly_contracts.dart';
import 'package:licoup/src/application/features/skill_hub/controller/skill_hub_controller.dart';
import 'package:licoup/src/application/features/skill_hub/controller/skill_hub_status.dart';
import 'package:licoup/src/application/features/skill_hub/controller/skill_delete_controller.dart';
import 'package:licoup/src/application/features/skill_hub/controller/skill_usage_controller.dart';
import 'package:licoup/src/application/features/skill_hub/services/local_skill_hub_catalog_source.dart';
import 'package:licoup/src/application/features/skill_hub/services/skill_delete_service.dart';
import 'package:licoup/src/application/features/skill_hub/services/skill_usage_service.dart';
import 'package:licoup/src/backend/features/skill_hub/services/skill_hub_preferences_service.dart';
import 'package:licoup/src/contracts/skill_delete.dart';
import 'package:licoup/src/contracts/skill_hub.dart';
import 'package:licoup/src/contracts/skill_usage.dart';
import 'package:licoup/src/platform/native_client/agent_service.dart';
import 'package:licoup/src/platform/storage/portable_data_root.dart';

final class ClientSkillComponentAssembly {
  ClientSkillComponentAssembly({
    required PortableDataRoot portableData,
    required AgentService agentService,
    required SkillHubPreferencesService preferencesService,
    required List<TargetCandidate> Function() targets,
    required Future<void> Function() ensureTargets,
    required ClientComponentStatusSink reportStatus,
    SkillHubGateway? skillHubGateway,
    SkillDeleteGateway? skillDeleteGateway,
    SkillUsageGateway? skillUsageGateway,
    SkillHubLocalCatalogSource? localCatalogSource,
  }) {
    resolvedGateway = skillHubGateway ?? agentService;
    void onStatus(SkillHubStatusUpdate update) => reportStatus(
      chinese: update.chinese,
      english: update.english,
      caption: 'Skill Hub',
      errorCode: update.errorCode,
    );

    controller = SkillHubController(
      gateway: resolvedGateway,
      preferencesRepository: preferencesService,
      localCatalogSource:
          localCatalogSource ?? const LocalSkillHubCatalogSource(),
      portableData: portableData,
      targets: targets,
      ensureTargets: ensureTargets,
      onStatus: onStatus,
    );
    deleteController = SkillDeleteController(
      service: SkillDeleteService(gateway: skillDeleteGateway ?? agentService),
      onStatus: onStatus,
    );
    usageController = SkillUsageController(
      service: SkillUsageService(gateway: skillUsageGateway ?? agentService),
      onStatus: onStatus,
    );
  }

  late final SkillHubGateway resolvedGateway;
  late final SkillHubController controller;
  late final SkillDeleteController deleteController;
  late final SkillUsageController usageController;

  void dispose() {
    usageController.dispose();
    deleteController.dispose();
    controller.dispose();
  }
}
