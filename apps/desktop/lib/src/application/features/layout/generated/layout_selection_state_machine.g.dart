// GENERATED CODE - DO NOT EDIT.
// Source: apps/desktop/resources/layout-selection-state-machine.json
// Refresh with tools/development/compile-dart-machines.mjs.

import 'package:licoup/src/contracts/presentation/layout_selection_status.dart';

enum LayoutSelectionEvent {
  reload,
  succeed,
  fail,
  beginCommit,
  stabilize,
  reject,
}

const LayoutSelectionStatus layoutSelectionStatusInitial =
    LayoutSelectionStatus.loading;

bool layoutSelectionStatusIsTerminal(LayoutSelectionStatus state) =>
    switch (state) {
      _ => false,
    };

String layoutSelectionStatusId(LayoutSelectionStatus state) => switch (state) {
  LayoutSelectionStatus.loading => 'loading',
  LayoutSelectionStatus.stable => 'stable',
  LayoutSelectionStatus.committing => 'committing',
  LayoutSelectionStatus.error => 'error',
};

LayoutSelectionStatus? layoutSelectionStatusFromId(String id) =>
    switch (id.trim().toLowerCase()) {
      'loading' => LayoutSelectionStatus.loading,
      'stable' => LayoutSelectionStatus.stable,
      'committing' => LayoutSelectionStatus.committing,
      'error' => LayoutSelectionStatus.error,
      _ => null,
    };

String layoutSelectionEventId(LayoutSelectionEvent event) => switch (event) {
  LayoutSelectionEvent.reload => 'reload',
  LayoutSelectionEvent.succeed => 'succeed',
  LayoutSelectionEvent.fail => 'fail',
  LayoutSelectionEvent.beginCommit => 'begin-commit',
  LayoutSelectionEvent.stabilize => 'stabilize',
  LayoutSelectionEvent.reject => 'reject',
};

LayoutSelectionEvent? layoutSelectionEventFromId(String id) =>
    switch (id.trim().toLowerCase()) {
      'reload' => LayoutSelectionEvent.reload,
      'succeed' => LayoutSelectionEvent.succeed,
      'fail' => LayoutSelectionEvent.fail,
      'begin-commit' => LayoutSelectionEvent.beginCommit,
      'stabilize' => LayoutSelectionEvent.stabilize,
      'reject' => LayoutSelectionEvent.reject,
      _ => null,
    };

LayoutSelectionStatus? transitionLayoutSelectionStatus(
  LayoutSelectionStatus state,
  LayoutSelectionEvent event,
) => switch ((state, event)) {
  (LayoutSelectionStatus.loading, LayoutSelectionEvent.reload) =>
    LayoutSelectionStatus.loading,
  (LayoutSelectionStatus.loading, LayoutSelectionEvent.succeed) =>
    LayoutSelectionStatus.stable,
  (LayoutSelectionStatus.loading, LayoutSelectionEvent.fail) =>
    LayoutSelectionStatus.error,
  (LayoutSelectionStatus.stable, LayoutSelectionEvent.beginCommit) =>
    LayoutSelectionStatus.committing,
  (LayoutSelectionStatus.error, LayoutSelectionEvent.beginCommit) =>
    LayoutSelectionStatus.committing,
  (LayoutSelectionStatus.committing, LayoutSelectionEvent.succeed) =>
    LayoutSelectionStatus.stable,
  (LayoutSelectionStatus.committing, LayoutSelectionEvent.fail) =>
    LayoutSelectionStatus.error,
  (LayoutSelectionStatus.stable, LayoutSelectionEvent.stabilize) =>
    LayoutSelectionStatus.stable,
  (LayoutSelectionStatus.error, LayoutSelectionEvent.stabilize) =>
    LayoutSelectionStatus.stable,
  (LayoutSelectionStatus.stable, LayoutSelectionEvent.reject) =>
    LayoutSelectionStatus.error,
  (LayoutSelectionStatus.error, LayoutSelectionEvent.reject) =>
    LayoutSelectionStatus.error,
  _ => null,
};
