// GENERATED CODE - DO NOT EDIT.
// Source: packages/presentation_runtime/resources/state-machines.json
// Refresh with tools/development/compile-dart-machines.mjs.

enum SourceConnectionState { idle, open, disconnected }

enum SourceConnectionEvent { release, opened, lost }

const SourceConnectionState sourceConnectionStateInitial =
    SourceConnectionState.idle;

bool sourceConnectionStateIsTerminal(SourceConnectionState state) =>
    switch (state) {
      _ => false,
    };

String sourceConnectionStateId(SourceConnectionState state) => switch (state) {
  SourceConnectionState.idle => 'idle',
  SourceConnectionState.open => 'open',
  SourceConnectionState.disconnected => 'disconnected',
};

SourceConnectionState? sourceConnectionStateFromId(String id) =>
    switch (id.trim().toLowerCase()) {
      'idle' => SourceConnectionState.idle,
      'open' => SourceConnectionState.open,
      'disconnected' => SourceConnectionState.disconnected,
      _ => null,
    };

String sourceConnectionEventId(SourceConnectionEvent event) => switch (event) {
  SourceConnectionEvent.release => 'release',
  SourceConnectionEvent.opened => 'opened',
  SourceConnectionEvent.lost => 'lost',
};

SourceConnectionEvent? sourceConnectionEventFromId(String id) =>
    switch (id.trim().toLowerCase()) {
      'release' => SourceConnectionEvent.release,
      'opened' => SourceConnectionEvent.opened,
      'lost' => SourceConnectionEvent.lost,
      _ => null,
    };

SourceConnectionState? transitionSourceConnectionState(
  SourceConnectionState state,
  SourceConnectionEvent event,
) => switch ((state, event)) {
  (SourceConnectionState.idle, SourceConnectionEvent.release) =>
    SourceConnectionState.idle,
  (SourceConnectionState.idle, SourceConnectionEvent.opened) =>
    SourceConnectionState.open,
  (SourceConnectionState.idle, SourceConnectionEvent.lost) =>
    SourceConnectionState.disconnected,
  (SourceConnectionState.open, SourceConnectionEvent.release) =>
    SourceConnectionState.idle,
  (SourceConnectionState.open, SourceConnectionEvent.lost) =>
    SourceConnectionState.disconnected,
  (SourceConnectionState.disconnected, SourceConnectionEvent.release) =>
    SourceConnectionState.idle,
  (SourceConnectionState.disconnected, SourceConnectionEvent.lost) =>
    SourceConnectionState.disconnected,
  _ => null,
};
