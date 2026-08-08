import 'package:licoup/src/application/features/agents/archive/conversation_archive_job_controller.dart';
import 'package:licoup/src/application/features/agents/archive/conversation_archive_profile_controller.dart';
import 'package:licoup/src/application/features/agents/archive/conversation_archive_settings_controller.dart';
import 'package:licoup/src/application/features/agents/archive/conversation_snapshot_collection_controller.dart';
import 'package:licoup/src/application/features/agents/workspace/agent_workspace_coordinator.dart';

export 'package:licoup/src/application/features/agents/archive/conversation_archive_job_controller.dart';
export 'package:licoup/src/application/features/agents/archive/conversation_archive_profile_controller.dart';
export 'package:licoup/src/application/features/agents/archive/conversation_archive_settings_controller.dart';
export 'package:licoup/src/application/features/agents/archive/conversation_snapshot_collection_controller.dart';

/// Composition marker for the independently testable archive lifecycles.
mixin ConversationArchiveController
    on
        AgentWorkspaceCoordinator,
        ConversationArchiveJobController,
        ConversationSnapshotCollectionController,
        ConversationArchiveProfileController,
        ConversationArchiveSettingsController {}
