// GENERATED CODE - DO NOT EDIT.
// Source: apps/desktop/resources/settings-state-machines.json
// Refresh with tools/development/compile-dart-machines.mjs.

enum SettingsAutostartPhase { loading, ready, applying, unsupported, failed }

enum SettingsAutostartEvent { load, apply, ready, unsupported, fail }

const SettingsAutostartPhase settingsAutostartPhaseInitial =
    SettingsAutostartPhase.loading;

bool settingsAutostartPhaseIsTerminal(SettingsAutostartPhase state) =>
    switch (state) {
      _ => false,
    };

String settingsAutostartPhaseId(SettingsAutostartPhase state) =>
    switch (state) {
      SettingsAutostartPhase.loading => 'loading',
      SettingsAutostartPhase.ready => 'ready',
      SettingsAutostartPhase.applying => 'applying',
      SettingsAutostartPhase.unsupported => 'unsupported',
      SettingsAutostartPhase.failed => 'failed',
    };

SettingsAutostartPhase? settingsAutostartPhaseFromId(String id) =>
    switch (id.trim().toLowerCase()) {
      'loading' => SettingsAutostartPhase.loading,
      'ready' => SettingsAutostartPhase.ready,
      'applying' => SettingsAutostartPhase.applying,
      'unsupported' => SettingsAutostartPhase.unsupported,
      'failed' => SettingsAutostartPhase.failed,
      _ => null,
    };

String settingsAutostartEventId(SettingsAutostartEvent event) =>
    switch (event) {
      SettingsAutostartEvent.load => 'load',
      SettingsAutostartEvent.apply => 'apply',
      SettingsAutostartEvent.ready => 'ready',
      SettingsAutostartEvent.unsupported => 'unsupported',
      SettingsAutostartEvent.fail => 'fail',
    };

SettingsAutostartEvent? settingsAutostartEventFromId(String id) =>
    switch (id.trim().toLowerCase()) {
      'load' => SettingsAutostartEvent.load,
      'apply' => SettingsAutostartEvent.apply,
      'ready' => SettingsAutostartEvent.ready,
      'unsupported' => SettingsAutostartEvent.unsupported,
      'fail' => SettingsAutostartEvent.fail,
      _ => null,
    };

SettingsAutostartPhase? transitionSettingsAutostartPhase(
  SettingsAutostartPhase state,
  SettingsAutostartEvent event,
) => switch ((state, event)) {
  (SettingsAutostartPhase.loading, SettingsAutostartEvent.load) =>
    SettingsAutostartPhase.loading,
  (SettingsAutostartPhase.ready, SettingsAutostartEvent.load) =>
    SettingsAutostartPhase.loading,
  (SettingsAutostartPhase.applying, SettingsAutostartEvent.load) =>
    SettingsAutostartPhase.loading,
  (SettingsAutostartPhase.unsupported, SettingsAutostartEvent.load) =>
    SettingsAutostartPhase.loading,
  (SettingsAutostartPhase.failed, SettingsAutostartEvent.load) =>
    SettingsAutostartPhase.loading,
  (SettingsAutostartPhase.ready, SettingsAutostartEvent.apply) =>
    SettingsAutostartPhase.applying,
  (SettingsAutostartPhase.loading, SettingsAutostartEvent.ready) =>
    SettingsAutostartPhase.ready,
  (SettingsAutostartPhase.ready, SettingsAutostartEvent.ready) =>
    SettingsAutostartPhase.ready,
  (SettingsAutostartPhase.applying, SettingsAutostartEvent.ready) =>
    SettingsAutostartPhase.ready,
  (SettingsAutostartPhase.unsupported, SettingsAutostartEvent.ready) =>
    SettingsAutostartPhase.ready,
  (SettingsAutostartPhase.failed, SettingsAutostartEvent.ready) =>
    SettingsAutostartPhase.ready,
  (SettingsAutostartPhase.loading, SettingsAutostartEvent.unsupported) =>
    SettingsAutostartPhase.unsupported,
  (SettingsAutostartPhase.ready, SettingsAutostartEvent.unsupported) =>
    SettingsAutostartPhase.unsupported,
  (SettingsAutostartPhase.applying, SettingsAutostartEvent.unsupported) =>
    SettingsAutostartPhase.unsupported,
  (SettingsAutostartPhase.unsupported, SettingsAutostartEvent.unsupported) =>
    SettingsAutostartPhase.unsupported,
  (SettingsAutostartPhase.failed, SettingsAutostartEvent.unsupported) =>
    SettingsAutostartPhase.unsupported,
  (SettingsAutostartPhase.loading, SettingsAutostartEvent.fail) =>
    SettingsAutostartPhase.failed,
  (SettingsAutostartPhase.ready, SettingsAutostartEvent.fail) =>
    SettingsAutostartPhase.failed,
  (SettingsAutostartPhase.applying, SettingsAutostartEvent.fail) =>
    SettingsAutostartPhase.failed,
  (SettingsAutostartPhase.unsupported, SettingsAutostartEvent.fail) =>
    SettingsAutostartPhase.failed,
  (SettingsAutostartPhase.failed, SettingsAutostartEvent.fail) =>
    SettingsAutostartPhase.failed,
  _ => null,
};
