// GENERATED CODE - DO NOT EDIT.
// Source: apps/desktop/resources/client-update-state-machine.json
// Refresh with tools/development/compile-dart-machines.mjs.

enum ClientUpdatePhase {
  idle,
  checking,
  upToDate,
  unavailable,
  updateAvailable,
  downloading,
  downloaded,
  verifying,
  verified,
  applyPlanned,
  applied,
  failed,
}

enum ClientUpdateEvent {
  reset,
  check,
  upToDate,
  unavailable,
  updateAvailable,
  download,
  downloaded,
  verify,
  verified,
  planApply,
  apply,
  fail,
}

const ClientUpdatePhase clientUpdatePhaseInitial = ClientUpdatePhase.idle;

bool clientUpdatePhaseIsTerminal(ClientUpdatePhase state) => switch (state) {
  _ => false,
};

String clientUpdatePhaseId(ClientUpdatePhase state) => switch (state) {
  ClientUpdatePhase.idle => 'idle',
  ClientUpdatePhase.checking => 'checking',
  ClientUpdatePhase.upToDate => 'up-to-date',
  ClientUpdatePhase.unavailable => 'unavailable',
  ClientUpdatePhase.updateAvailable => 'update-available',
  ClientUpdatePhase.downloading => 'downloading',
  ClientUpdatePhase.downloaded => 'downloaded',
  ClientUpdatePhase.verifying => 'verifying',
  ClientUpdatePhase.verified => 'verified',
  ClientUpdatePhase.applyPlanned => 'apply-planned',
  ClientUpdatePhase.applied => 'applied',
  ClientUpdatePhase.failed => 'failed',
};

ClientUpdatePhase? clientUpdatePhaseFromId(String id) =>
    switch (id.trim().toLowerCase()) {
      'idle' => ClientUpdatePhase.idle,
      'checking' => ClientUpdatePhase.checking,
      'up-to-date' => ClientUpdatePhase.upToDate,
      'unavailable' => ClientUpdatePhase.unavailable,
      'update-available' => ClientUpdatePhase.updateAvailable,
      'downloading' => ClientUpdatePhase.downloading,
      'downloaded' => ClientUpdatePhase.downloaded,
      'verifying' => ClientUpdatePhase.verifying,
      'verified' => ClientUpdatePhase.verified,
      'apply-planned' => ClientUpdatePhase.applyPlanned,
      'applied' => ClientUpdatePhase.applied,
      'failed' => ClientUpdatePhase.failed,
      _ => null,
    };

String clientUpdateEventId(ClientUpdateEvent event) => switch (event) {
  ClientUpdateEvent.reset => 'reset',
  ClientUpdateEvent.check => 'check',
  ClientUpdateEvent.upToDate => 'up-to-date',
  ClientUpdateEvent.unavailable => 'unavailable',
  ClientUpdateEvent.updateAvailable => 'update-available',
  ClientUpdateEvent.download => 'download',
  ClientUpdateEvent.downloaded => 'downloaded',
  ClientUpdateEvent.verify => 'verify',
  ClientUpdateEvent.verified => 'verified',
  ClientUpdateEvent.planApply => 'plan-apply',
  ClientUpdateEvent.apply => 'apply',
  ClientUpdateEvent.fail => 'fail',
};

ClientUpdateEvent? clientUpdateEventFromId(String id) =>
    switch (id.trim().toLowerCase()) {
      'reset' => ClientUpdateEvent.reset,
      'check' => ClientUpdateEvent.check,
      'up-to-date' => ClientUpdateEvent.upToDate,
      'unavailable' => ClientUpdateEvent.unavailable,
      'update-available' => ClientUpdateEvent.updateAvailable,
      'download' => ClientUpdateEvent.download,
      'downloaded' => ClientUpdateEvent.downloaded,
      'verify' => ClientUpdateEvent.verify,
      'verified' => ClientUpdateEvent.verified,
      'plan-apply' => ClientUpdateEvent.planApply,
      'apply' => ClientUpdateEvent.apply,
      'fail' => ClientUpdateEvent.fail,
      _ => null,
    };

ClientUpdatePhase? transitionClientUpdatePhase(
  ClientUpdatePhase state,
  ClientUpdateEvent event,
) => switch ((state, event)) {
  (ClientUpdatePhase.idle, ClientUpdateEvent.reset) => ClientUpdatePhase.idle,
  (ClientUpdatePhase.checking, ClientUpdateEvent.reset) =>
    ClientUpdatePhase.idle,
  (ClientUpdatePhase.upToDate, ClientUpdateEvent.reset) =>
    ClientUpdatePhase.idle,
  (ClientUpdatePhase.unavailable, ClientUpdateEvent.reset) =>
    ClientUpdatePhase.idle,
  (ClientUpdatePhase.updateAvailable, ClientUpdateEvent.reset) =>
    ClientUpdatePhase.idle,
  (ClientUpdatePhase.downloading, ClientUpdateEvent.reset) =>
    ClientUpdatePhase.idle,
  (ClientUpdatePhase.downloaded, ClientUpdateEvent.reset) =>
    ClientUpdatePhase.idle,
  (ClientUpdatePhase.verifying, ClientUpdateEvent.reset) =>
    ClientUpdatePhase.idle,
  (ClientUpdatePhase.verified, ClientUpdateEvent.reset) =>
    ClientUpdatePhase.idle,
  (ClientUpdatePhase.applyPlanned, ClientUpdateEvent.reset) =>
    ClientUpdatePhase.idle,
  (ClientUpdatePhase.applied, ClientUpdateEvent.reset) =>
    ClientUpdatePhase.idle,
  (ClientUpdatePhase.failed, ClientUpdateEvent.reset) => ClientUpdatePhase.idle,
  (ClientUpdatePhase.idle, ClientUpdateEvent.check) =>
    ClientUpdatePhase.checking,
  (ClientUpdatePhase.upToDate, ClientUpdateEvent.check) =>
    ClientUpdatePhase.checking,
  (ClientUpdatePhase.unavailable, ClientUpdateEvent.check) =>
    ClientUpdatePhase.checking,
  (ClientUpdatePhase.updateAvailable, ClientUpdateEvent.check) =>
    ClientUpdatePhase.checking,
  (ClientUpdatePhase.downloaded, ClientUpdateEvent.check) =>
    ClientUpdatePhase.checking,
  (ClientUpdatePhase.verified, ClientUpdateEvent.check) =>
    ClientUpdatePhase.checking,
  (ClientUpdatePhase.applyPlanned, ClientUpdateEvent.check) =>
    ClientUpdatePhase.checking,
  (ClientUpdatePhase.applied, ClientUpdateEvent.check) =>
    ClientUpdatePhase.checking,
  (ClientUpdatePhase.failed, ClientUpdateEvent.check) =>
    ClientUpdatePhase.checking,
  (ClientUpdatePhase.checking, ClientUpdateEvent.upToDate) =>
    ClientUpdatePhase.upToDate,
  (ClientUpdatePhase.checking, ClientUpdateEvent.unavailable) =>
    ClientUpdatePhase.unavailable,
  (ClientUpdatePhase.checking, ClientUpdateEvent.updateAvailable) =>
    ClientUpdatePhase.updateAvailable,
  (ClientUpdatePhase.updateAvailable, ClientUpdateEvent.download) =>
    ClientUpdatePhase.downloading,
  (ClientUpdatePhase.downloading, ClientUpdateEvent.downloaded) =>
    ClientUpdatePhase.downloaded,
  (ClientUpdatePhase.downloaded, ClientUpdateEvent.verify) =>
    ClientUpdatePhase.verifying,
  (ClientUpdatePhase.verifying, ClientUpdateEvent.verified) =>
    ClientUpdatePhase.verified,
  (ClientUpdatePhase.verified, ClientUpdateEvent.planApply) =>
    ClientUpdatePhase.applyPlanned,
  (ClientUpdatePhase.applyPlanned, ClientUpdateEvent.planApply) =>
    ClientUpdatePhase.applyPlanned,
  (ClientUpdatePhase.verified, ClientUpdateEvent.apply) =>
    ClientUpdatePhase.applied,
  (ClientUpdatePhase.applyPlanned, ClientUpdateEvent.apply) =>
    ClientUpdatePhase.applied,
  (ClientUpdatePhase.idle, ClientUpdateEvent.fail) => ClientUpdatePhase.failed,
  (ClientUpdatePhase.checking, ClientUpdateEvent.fail) =>
    ClientUpdatePhase.failed,
  (ClientUpdatePhase.upToDate, ClientUpdateEvent.fail) =>
    ClientUpdatePhase.failed,
  (ClientUpdatePhase.unavailable, ClientUpdateEvent.fail) =>
    ClientUpdatePhase.failed,
  (ClientUpdatePhase.updateAvailable, ClientUpdateEvent.fail) =>
    ClientUpdatePhase.failed,
  (ClientUpdatePhase.downloading, ClientUpdateEvent.fail) =>
    ClientUpdatePhase.failed,
  (ClientUpdatePhase.downloaded, ClientUpdateEvent.fail) =>
    ClientUpdatePhase.failed,
  (ClientUpdatePhase.verifying, ClientUpdateEvent.fail) =>
    ClientUpdatePhase.failed,
  (ClientUpdatePhase.verified, ClientUpdateEvent.fail) =>
    ClientUpdatePhase.failed,
  (ClientUpdatePhase.applyPlanned, ClientUpdateEvent.fail) =>
    ClientUpdatePhase.failed,
  (ClientUpdatePhase.applied, ClientUpdateEvent.fail) =>
    ClientUpdatePhase.failed,
  (ClientUpdatePhase.failed, ClientUpdateEvent.fail) =>
    ClientUpdatePhase.failed,
  _ => null,
};
