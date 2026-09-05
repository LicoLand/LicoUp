import 'package:licoup/src/frontend/features/agents/ui/agent_render_adapter.dart';

export 'dart:convert';

export 'package:flutter/material.dart';
export 'package:flutter/services.dart';
export 'package:licoup/src/application/controller/client_controller.dart';
export 'package:licoup/src/backend/features/agents/services/agent_conversation_service.dart';
export 'package:licoup/src/frontend/features/agents/ui/agent_conversation_workspace.dart';
export 'package:licoup/src/frontend/features/agents/ui/agent_render_adapter.dart';
export 'package:licoup/src/frontend/features/agents/ui/agent_workspace_sidebar.dart';
export 'package:licoup/src/frontend/l10n/lico_strings.dart';
export 'package:licoup/src/frontend/shared/ui/theme.dart';
export 'package:licoup/src/platform/native_client/agent_service.dart';
export 'package:flutter_localizations/flutter_localizations.dart';
export 'package:flutter_test/flutter_test.dart';

export '../../layout/fixtures/layout_destination_presentation_fixture.dart';
export '../../support/agent_conversation_workspace_fixture.dart';

class CountingAgentRenderAdapterRegistry extends AgentRenderAdapterRegistry {
  int resolveCalls = 0;

  @override
  Future<AgentRenderAdapter> resolve({
    required String agentId,
    String sourceClient = '',
    String sourceTool = '',
    String adapterId = '',
  }) {
    resolveCalls += 1;
    return Future<AgentRenderAdapter>.value(AgentRenderAdapter.fallback());
  }
}
