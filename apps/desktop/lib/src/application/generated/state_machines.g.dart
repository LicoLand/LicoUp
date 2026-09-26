// GENERATED CODE - DO NOT EDIT.
// Source: apps/desktop/resources/state-machines.json
// Refresh with tools/development/compile-dart-machines.mjs.

enum ClientLifecyclePhase { idle, initializing, ready, failed, disposed }

enum ClientLifecycleEvent {
  initialize,
  initializationSucceeded,
  initializationFailed,
  dispose,
}

const ClientLifecyclePhase clientLifecyclePhaseInitial =
    ClientLifecyclePhase.idle;

bool clientLifecyclePhaseIsTerminal(ClientLifecyclePhase state) =>
    switch (state) {
      ClientLifecyclePhase.disposed => true,
      _ => false,
    };

String clientLifecyclePhaseId(ClientLifecyclePhase state) => switch (state) {
  ClientLifecyclePhase.idle => 'idle',
  ClientLifecyclePhase.initializing => 'initializing',
  ClientLifecyclePhase.ready => 'ready',
  ClientLifecyclePhase.failed => 'failed',
  ClientLifecyclePhase.disposed => 'disposed',
};

ClientLifecyclePhase? clientLifecyclePhaseFromId(String id) =>
    switch (id.trim().toLowerCase()) {
      'idle' => ClientLifecyclePhase.idle,
      'initializing' => ClientLifecyclePhase.initializing,
      'ready' => ClientLifecyclePhase.ready,
      'failed' => ClientLifecyclePhase.failed,
      'disposed' => ClientLifecyclePhase.disposed,
      _ => null,
    };

String clientLifecycleEventId(ClientLifecycleEvent event) => switch (event) {
  ClientLifecycleEvent.initialize => 'initialize',
  ClientLifecycleEvent.initializationSucceeded => 'initialization-succeeded',
  ClientLifecycleEvent.initializationFailed => 'initialization-failed',
  ClientLifecycleEvent.dispose => 'dispose',
};

ClientLifecycleEvent? clientLifecycleEventFromId(String id) => switch (id
    .trim()
    .toLowerCase()) {
  'initialize' => ClientLifecycleEvent.initialize,
  'initialization-succeeded' => ClientLifecycleEvent.initializationSucceeded,
  'initialization-failed' => ClientLifecycleEvent.initializationFailed,
  'dispose' => ClientLifecycleEvent.dispose,
  _ => null,
};

ClientLifecyclePhase? transitionClientLifecyclePhase(
  ClientLifecyclePhase state,
  ClientLifecycleEvent event,
) => switch ((state, event)) {
  (ClientLifecyclePhase.idle, ClientLifecycleEvent.initialize) =>
    ClientLifecyclePhase.initializing,
  (ClientLifecyclePhase.failed, ClientLifecycleEvent.initialize) =>
    ClientLifecyclePhase.initializing,
  (
    ClientLifecyclePhase.initializing,
    ClientLifecycleEvent.initializationSucceeded,
  ) =>
    ClientLifecyclePhase.ready,
  (
    ClientLifecyclePhase.initializing,
    ClientLifecycleEvent.initializationFailed,
  ) =>
    ClientLifecyclePhase.failed,
  (ClientLifecyclePhase.idle, ClientLifecycleEvent.dispose) =>
    ClientLifecyclePhase.disposed,
  (ClientLifecyclePhase.initializing, ClientLifecycleEvent.dispose) =>
    ClientLifecyclePhase.disposed,
  (ClientLifecyclePhase.ready, ClientLifecycleEvent.dispose) =>
    ClientLifecyclePhase.disposed,
  (ClientLifecyclePhase.failed, ClientLifecycleEvent.dispose) =>
    ClientLifecyclePhase.disposed,
  _ => null,
};

ClientLifecycleEvent? clientLifecycleEventForTransition(
  ClientLifecyclePhase state,
  ClientLifecyclePhase target,
) => switch ((state, target)) {
  (ClientLifecyclePhase.idle, ClientLifecyclePhase.initializing) =>
    ClientLifecycleEvent.initialize,
  (ClientLifecyclePhase.failed, ClientLifecyclePhase.initializing) =>
    ClientLifecycleEvent.initialize,
  (ClientLifecyclePhase.initializing, ClientLifecyclePhase.ready) =>
    ClientLifecycleEvent.initializationSucceeded,
  (ClientLifecyclePhase.initializing, ClientLifecyclePhase.failed) =>
    ClientLifecycleEvent.initializationFailed,
  (ClientLifecyclePhase.idle, ClientLifecyclePhase.disposed) =>
    ClientLifecycleEvent.dispose,
  (ClientLifecyclePhase.initializing, ClientLifecyclePhase.disposed) =>
    ClientLifecycleEvent.dispose,
  (ClientLifecyclePhase.ready, ClientLifecyclePhase.disposed) =>
    ClientLifecycleEvent.dispose,
  (ClientLifecyclePhase.failed, ClientLifecyclePhase.disposed) =>
    ClientLifecycleEvent.dispose,
  _ => null,
};

enum CatalogConvergencePhase {
  disabled,
  idle,
  reconciling,
  ready,
  blocked,
  failed,
}

enum CatalogConvergenceEvent {
  notConfigured,
  reconciliationRequired,
  reconcile,
  current,
  block,
  statusFailed,
  disable,
}

const CatalogConvergencePhase catalogConvergencePhaseInitial =
    CatalogConvergencePhase.disabled;

bool catalogConvergencePhaseIsTerminal(CatalogConvergencePhase state) =>
    switch (state) {
      _ => false,
    };

String catalogConvergencePhaseId(CatalogConvergencePhase state) =>
    switch (state) {
      CatalogConvergencePhase.disabled => 'disabled',
      CatalogConvergencePhase.idle => 'idle',
      CatalogConvergencePhase.reconciling => 'reconciling',
      CatalogConvergencePhase.ready => 'ready',
      CatalogConvergencePhase.blocked => 'blocked',
      CatalogConvergencePhase.failed => 'failed',
    };

CatalogConvergencePhase? catalogConvergencePhaseFromId(String id) =>
    switch (id.trim().toLowerCase()) {
      'disabled' => CatalogConvergencePhase.disabled,
      'idle' => CatalogConvergencePhase.idle,
      'reconciling' => CatalogConvergencePhase.reconciling,
      'ready' => CatalogConvergencePhase.ready,
      'blocked' => CatalogConvergencePhase.blocked,
      'failed' => CatalogConvergencePhase.failed,
      _ => null,
    };

String catalogConvergenceEventId(CatalogConvergenceEvent event) =>
    switch (event) {
      CatalogConvergenceEvent.notConfigured => 'not-configured',
      CatalogConvergenceEvent.reconciliationRequired =>
        'reconciliation-required',
      CatalogConvergenceEvent.reconcile => 'reconcile',
      CatalogConvergenceEvent.current => 'current',
      CatalogConvergenceEvent.block => 'block',
      CatalogConvergenceEvent.statusFailed => 'status-failed',
      CatalogConvergenceEvent.disable => 'disable',
    };

CatalogConvergenceEvent? catalogConvergenceEventFromId(String id) => switch (id
    .trim()
    .toLowerCase()) {
  'not-configured' => CatalogConvergenceEvent.notConfigured,
  'reconciliation-required' => CatalogConvergenceEvent.reconciliationRequired,
  'reconcile' => CatalogConvergenceEvent.reconcile,
  'current' => CatalogConvergenceEvent.current,
  'block' => CatalogConvergenceEvent.block,
  'status-failed' => CatalogConvergenceEvent.statusFailed,
  'disable' => CatalogConvergenceEvent.disable,
  _ => null,
};

CatalogConvergencePhase? transitionCatalogConvergencePhase(
  CatalogConvergencePhase state,
  CatalogConvergenceEvent event,
) => switch ((state, event)) {
  (CatalogConvergencePhase.disabled, CatalogConvergenceEvent.notConfigured) =>
    CatalogConvergencePhase.disabled,
  (CatalogConvergencePhase.idle, CatalogConvergenceEvent.notConfigured) =>
    CatalogConvergencePhase.disabled,
  (
    CatalogConvergencePhase.reconciling,
    CatalogConvergenceEvent.notConfigured,
  ) =>
    CatalogConvergencePhase.disabled,
  (CatalogConvergencePhase.ready, CatalogConvergenceEvent.notConfigured) =>
    CatalogConvergencePhase.disabled,
  (CatalogConvergencePhase.blocked, CatalogConvergenceEvent.notConfigured) =>
    CatalogConvergencePhase.disabled,
  (CatalogConvergencePhase.failed, CatalogConvergenceEvent.notConfigured) =>
    CatalogConvergencePhase.disabled,
  (
    CatalogConvergencePhase.disabled,
    CatalogConvergenceEvent.reconciliationRequired,
  ) =>
    CatalogConvergencePhase.blocked,
  (
    CatalogConvergencePhase.idle,
    CatalogConvergenceEvent.reconciliationRequired,
  ) =>
    CatalogConvergencePhase.blocked,
  (
    CatalogConvergencePhase.reconciling,
    CatalogConvergenceEvent.reconciliationRequired,
  ) =>
    CatalogConvergencePhase.blocked,
  (
    CatalogConvergencePhase.ready,
    CatalogConvergenceEvent.reconciliationRequired,
  ) =>
    CatalogConvergencePhase.blocked,
  (
    CatalogConvergencePhase.blocked,
    CatalogConvergenceEvent.reconciliationRequired,
  ) =>
    CatalogConvergencePhase.blocked,
  (
    CatalogConvergencePhase.failed,
    CatalogConvergenceEvent.reconciliationRequired,
  ) =>
    CatalogConvergencePhase.blocked,
  (CatalogConvergencePhase.disabled, CatalogConvergenceEvent.reconcile) =>
    CatalogConvergencePhase.reconciling,
  (CatalogConvergencePhase.idle, CatalogConvergenceEvent.reconcile) =>
    CatalogConvergencePhase.reconciling,
  (CatalogConvergencePhase.reconciling, CatalogConvergenceEvent.reconcile) =>
    CatalogConvergencePhase.reconciling,
  (CatalogConvergencePhase.ready, CatalogConvergenceEvent.reconcile) =>
    CatalogConvergencePhase.reconciling,
  (CatalogConvergencePhase.blocked, CatalogConvergenceEvent.reconcile) =>
    CatalogConvergencePhase.reconciling,
  (CatalogConvergencePhase.failed, CatalogConvergenceEvent.reconcile) =>
    CatalogConvergencePhase.reconciling,
  (CatalogConvergencePhase.disabled, CatalogConvergenceEvent.current) =>
    CatalogConvergencePhase.ready,
  (CatalogConvergencePhase.idle, CatalogConvergenceEvent.current) =>
    CatalogConvergencePhase.ready,
  (CatalogConvergencePhase.reconciling, CatalogConvergenceEvent.current) =>
    CatalogConvergencePhase.ready,
  (CatalogConvergencePhase.ready, CatalogConvergenceEvent.current) =>
    CatalogConvergencePhase.ready,
  (CatalogConvergencePhase.blocked, CatalogConvergenceEvent.current) =>
    CatalogConvergencePhase.ready,
  (CatalogConvergencePhase.failed, CatalogConvergenceEvent.current) =>
    CatalogConvergencePhase.ready,
  (CatalogConvergencePhase.disabled, CatalogConvergenceEvent.block) =>
    CatalogConvergencePhase.blocked,
  (CatalogConvergencePhase.idle, CatalogConvergenceEvent.block) =>
    CatalogConvergencePhase.blocked,
  (CatalogConvergencePhase.reconciling, CatalogConvergenceEvent.block) =>
    CatalogConvergencePhase.blocked,
  (CatalogConvergencePhase.ready, CatalogConvergenceEvent.block) =>
    CatalogConvergencePhase.blocked,
  (CatalogConvergencePhase.blocked, CatalogConvergenceEvent.block) =>
    CatalogConvergencePhase.blocked,
  (CatalogConvergencePhase.failed, CatalogConvergenceEvent.block) =>
    CatalogConvergencePhase.blocked,
  (CatalogConvergencePhase.disabled, CatalogConvergenceEvent.statusFailed) =>
    CatalogConvergencePhase.failed,
  (CatalogConvergencePhase.idle, CatalogConvergenceEvent.statusFailed) =>
    CatalogConvergencePhase.failed,
  (CatalogConvergencePhase.reconciling, CatalogConvergenceEvent.statusFailed) =>
    CatalogConvergencePhase.failed,
  (CatalogConvergencePhase.ready, CatalogConvergenceEvent.statusFailed) =>
    CatalogConvergencePhase.failed,
  (CatalogConvergencePhase.blocked, CatalogConvergenceEvent.statusFailed) =>
    CatalogConvergencePhase.failed,
  (CatalogConvergencePhase.failed, CatalogConvergenceEvent.statusFailed) =>
    CatalogConvergencePhase.failed,
  (CatalogConvergencePhase.disabled, CatalogConvergenceEvent.disable) =>
    CatalogConvergencePhase.disabled,
  (CatalogConvergencePhase.idle, CatalogConvergenceEvent.disable) =>
    CatalogConvergencePhase.disabled,
  (CatalogConvergencePhase.reconciling, CatalogConvergenceEvent.disable) =>
    CatalogConvergencePhase.disabled,
  (CatalogConvergencePhase.ready, CatalogConvergenceEvent.disable) =>
    CatalogConvergencePhase.disabled,
  (CatalogConvergencePhase.blocked, CatalogConvergenceEvent.disable) =>
    CatalogConvergencePhase.disabled,
  (CatalogConvergencePhase.failed, CatalogConvergenceEvent.disable) =>
    CatalogConvergencePhase.disabled,
};

enum LlmGatewayRuntimeState { unknown, running, stopped, unhealthy }

enum LlmGatewayRuntimeEvent {
  reportUnknown,
  reportRunning,
  reportStopped,
  reportUnhealthy,
}

const LlmGatewayRuntimeState llmGatewayRuntimeStateInitial =
    LlmGatewayRuntimeState.unknown;

bool llmGatewayRuntimeStateIsTerminal(LlmGatewayRuntimeState state) =>
    switch (state) {
      _ => false,
    };

String llmGatewayRuntimeStateId(LlmGatewayRuntimeState state) =>
    switch (state) {
      LlmGatewayRuntimeState.unknown => 'unknown',
      LlmGatewayRuntimeState.running => 'running',
      LlmGatewayRuntimeState.stopped => 'stopped',
      LlmGatewayRuntimeState.unhealthy => 'unhealthy',
    };

LlmGatewayRuntimeState? llmGatewayRuntimeStateFromId(String id) =>
    switch (id.trim().toLowerCase()) {
      'unknown' => LlmGatewayRuntimeState.unknown,
      'running' => LlmGatewayRuntimeState.running,
      'stopped' => LlmGatewayRuntimeState.stopped,
      'unhealthy' => LlmGatewayRuntimeState.unhealthy,
      _ => null,
    };

String llmGatewayRuntimeEventId(LlmGatewayRuntimeEvent event) =>
    switch (event) {
      LlmGatewayRuntimeEvent.reportUnknown => 'report-unknown',
      LlmGatewayRuntimeEvent.reportRunning => 'report-running',
      LlmGatewayRuntimeEvent.reportStopped => 'report-stopped',
      LlmGatewayRuntimeEvent.reportUnhealthy => 'report-unhealthy',
    };

LlmGatewayRuntimeEvent? llmGatewayRuntimeEventFromId(String id) =>
    switch (id.trim().toLowerCase()) {
      'report-unknown' => LlmGatewayRuntimeEvent.reportUnknown,
      'report-running' => LlmGatewayRuntimeEvent.reportRunning,
      'report-stopped' => LlmGatewayRuntimeEvent.reportStopped,
      'report-unhealthy' => LlmGatewayRuntimeEvent.reportUnhealthy,
      _ => null,
    };

LlmGatewayRuntimeState? transitionLlmGatewayRuntimeState(
  LlmGatewayRuntimeState state,
  LlmGatewayRuntimeEvent event,
) => switch ((state, event)) {
  (LlmGatewayRuntimeState.unknown, LlmGatewayRuntimeEvent.reportUnknown) =>
    LlmGatewayRuntimeState.unknown,
  (LlmGatewayRuntimeState.running, LlmGatewayRuntimeEvent.reportUnknown) =>
    LlmGatewayRuntimeState.unknown,
  (LlmGatewayRuntimeState.stopped, LlmGatewayRuntimeEvent.reportUnknown) =>
    LlmGatewayRuntimeState.unknown,
  (LlmGatewayRuntimeState.unhealthy, LlmGatewayRuntimeEvent.reportUnknown) =>
    LlmGatewayRuntimeState.unknown,
  (LlmGatewayRuntimeState.unknown, LlmGatewayRuntimeEvent.reportRunning) =>
    LlmGatewayRuntimeState.running,
  (LlmGatewayRuntimeState.running, LlmGatewayRuntimeEvent.reportRunning) =>
    LlmGatewayRuntimeState.running,
  (LlmGatewayRuntimeState.stopped, LlmGatewayRuntimeEvent.reportRunning) =>
    LlmGatewayRuntimeState.running,
  (LlmGatewayRuntimeState.unhealthy, LlmGatewayRuntimeEvent.reportRunning) =>
    LlmGatewayRuntimeState.running,
  (LlmGatewayRuntimeState.unknown, LlmGatewayRuntimeEvent.reportStopped) =>
    LlmGatewayRuntimeState.stopped,
  (LlmGatewayRuntimeState.running, LlmGatewayRuntimeEvent.reportStopped) =>
    LlmGatewayRuntimeState.stopped,
  (LlmGatewayRuntimeState.stopped, LlmGatewayRuntimeEvent.reportStopped) =>
    LlmGatewayRuntimeState.stopped,
  (LlmGatewayRuntimeState.unhealthy, LlmGatewayRuntimeEvent.reportStopped) =>
    LlmGatewayRuntimeState.stopped,
  (LlmGatewayRuntimeState.unknown, LlmGatewayRuntimeEvent.reportUnhealthy) =>
    LlmGatewayRuntimeState.unhealthy,
  (LlmGatewayRuntimeState.running, LlmGatewayRuntimeEvent.reportUnhealthy) =>
    LlmGatewayRuntimeState.unhealthy,
  (LlmGatewayRuntimeState.stopped, LlmGatewayRuntimeEvent.reportUnhealthy) =>
    LlmGatewayRuntimeState.unhealthy,
  (LlmGatewayRuntimeState.unhealthy, LlmGatewayRuntimeEvent.reportUnhealthy) =>
    LlmGatewayRuntimeState.unhealthy,
};

enum ConversationTurnProcessStage {
  submitted,
  accepted,
  processing,
  responding,
  completed,
  failed,
}

enum ConversationTurnProcessEvent {
  submitted,
  accepted,
  processing,
  responding,
  completed,
  failed,
}

const ConversationTurnProcessStage conversationTurnProcessStageInitial =
    ConversationTurnProcessStage.submitted;

bool conversationTurnProcessStageIsTerminal(
  ConversationTurnProcessStage state,
) => switch (state) {
  ConversationTurnProcessStage.failed => true,
  _ => false,
};

String conversationTurnProcessStageId(ConversationTurnProcessStage state) =>
    switch (state) {
      ConversationTurnProcessStage.submitted => 'submitted',
      ConversationTurnProcessStage.accepted => 'accepted',
      ConversationTurnProcessStage.processing => 'processing',
      ConversationTurnProcessStage.responding => 'responding',
      ConversationTurnProcessStage.completed => 'completed',
      ConversationTurnProcessStage.failed => 'failed',
    };

ConversationTurnProcessStage? conversationTurnProcessStageFromId(String id) =>
    switch (id.trim().toLowerCase()) {
      'submitted' => ConversationTurnProcessStage.submitted,
      'accepted' => ConversationTurnProcessStage.accepted,
      'processing' => ConversationTurnProcessStage.processing,
      'responding' => ConversationTurnProcessStage.responding,
      'completed' => ConversationTurnProcessStage.completed,
      'failed' => ConversationTurnProcessStage.failed,
      _ => null,
    };

String conversationTurnProcessEventId(ConversationTurnProcessEvent event) =>
    switch (event) {
      ConversationTurnProcessEvent.submitted => 'submitted',
      ConversationTurnProcessEvent.accepted => 'accepted',
      ConversationTurnProcessEvent.processing => 'processing',
      ConversationTurnProcessEvent.responding => 'responding',
      ConversationTurnProcessEvent.completed => 'completed',
      ConversationTurnProcessEvent.failed => 'failed',
    };

ConversationTurnProcessEvent? conversationTurnProcessEventFromId(String id) =>
    switch (id.trim().toLowerCase()) {
      'submitted' => ConversationTurnProcessEvent.submitted,
      'accepted' => ConversationTurnProcessEvent.accepted,
      'processing' => ConversationTurnProcessEvent.processing,
      'responding' => ConversationTurnProcessEvent.responding,
      'completed' => ConversationTurnProcessEvent.completed,
      'failed' => ConversationTurnProcessEvent.failed,
      _ => null,
    };

ConversationTurnProcessStage? transitionConversationTurnProcessStage(
  ConversationTurnProcessStage state,
  ConversationTurnProcessEvent event,
) => switch ((state, event)) {
  (
    ConversationTurnProcessStage.submitted,
    ConversationTurnProcessEvent.submitted,
  ) =>
    ConversationTurnProcessStage.submitted,
  (
    ConversationTurnProcessStage.submitted,
    ConversationTurnProcessEvent.accepted,
  ) =>
    ConversationTurnProcessStage.accepted,
  (
    ConversationTurnProcessStage.submitted,
    ConversationTurnProcessEvent.processing,
  ) =>
    ConversationTurnProcessStage.processing,
  (
    ConversationTurnProcessStage.submitted,
    ConversationTurnProcessEvent.responding,
  ) =>
    ConversationTurnProcessStage.responding,
  (
    ConversationTurnProcessStage.submitted,
    ConversationTurnProcessEvent.completed,
  ) =>
    ConversationTurnProcessStage.completed,
  (
    ConversationTurnProcessStage.submitted,
    ConversationTurnProcessEvent.failed,
  ) =>
    ConversationTurnProcessStage.failed,
  (
    ConversationTurnProcessStage.accepted,
    ConversationTurnProcessEvent.accepted,
  ) =>
    ConversationTurnProcessStage.accepted,
  (
    ConversationTurnProcessStage.accepted,
    ConversationTurnProcessEvent.processing,
  ) =>
    ConversationTurnProcessStage.processing,
  (
    ConversationTurnProcessStage.accepted,
    ConversationTurnProcessEvent.responding,
  ) =>
    ConversationTurnProcessStage.responding,
  (
    ConversationTurnProcessStage.accepted,
    ConversationTurnProcessEvent.completed,
  ) =>
    ConversationTurnProcessStage.completed,
  (
    ConversationTurnProcessStage.accepted,
    ConversationTurnProcessEvent.failed,
  ) =>
    ConversationTurnProcessStage.failed,
  (
    ConversationTurnProcessStage.processing,
    ConversationTurnProcessEvent.processing,
  ) =>
    ConversationTurnProcessStage.processing,
  (
    ConversationTurnProcessStage.processing,
    ConversationTurnProcessEvent.responding,
  ) =>
    ConversationTurnProcessStage.responding,
  (
    ConversationTurnProcessStage.processing,
    ConversationTurnProcessEvent.completed,
  ) =>
    ConversationTurnProcessStage.completed,
  (
    ConversationTurnProcessStage.processing,
    ConversationTurnProcessEvent.failed,
  ) =>
    ConversationTurnProcessStage.failed,
  (
    ConversationTurnProcessStage.responding,
    ConversationTurnProcessEvent.responding,
  ) =>
    ConversationTurnProcessStage.responding,
  (
    ConversationTurnProcessStage.responding,
    ConversationTurnProcessEvent.completed,
  ) =>
    ConversationTurnProcessStage.completed,
  (
    ConversationTurnProcessStage.responding,
    ConversationTurnProcessEvent.failed,
  ) =>
    ConversationTurnProcessStage.failed,
  (
    ConversationTurnProcessStage.completed,
    ConversationTurnProcessEvent.completed,
  ) =>
    ConversationTurnProcessStage.completed,
  (
    ConversationTurnProcessStage.completed,
    ConversationTurnProcessEvent.failed,
  ) =>
    ConversationTurnProcessStage.failed,
  _ => null,
};
