// GENERATED CODE - DO NOT EDIT.
// Source: packages/presentation_contract/resources/state-machines.json
// Refresh with tools/development/compile-dart-machines.mjs.

enum PreparationStatus { active, revoked, disposed }

enum PreparationEvent { revoke, dispose }

const PreparationStatus preparationStatusInitial = PreparationStatus.active;

bool preparationStatusIsTerminal(PreparationStatus state) => switch (state) {
  PreparationStatus.disposed => true,
  _ => false,
};

String preparationStatusId(PreparationStatus state) => switch (state) {
  PreparationStatus.active => 'active',
  PreparationStatus.revoked => 'revoked',
  PreparationStatus.disposed => 'disposed',
};

PreparationStatus? preparationStatusFromId(String id) =>
    switch (id.trim().toLowerCase()) {
      'active' => PreparationStatus.active,
      'revoked' => PreparationStatus.revoked,
      'disposed' => PreparationStatus.disposed,
      _ => null,
    };

String preparationEventId(PreparationEvent event) => switch (event) {
  PreparationEvent.revoke => 'revoke',
  PreparationEvent.dispose => 'dispose',
};

PreparationEvent? preparationEventFromId(String id) =>
    switch (id.trim().toLowerCase()) {
      'revoke' => PreparationEvent.revoke,
      'dispose' => PreparationEvent.dispose,
      _ => null,
    };

PreparationStatus? transitionPreparationStatus(
  PreparationStatus state,
  PreparationEvent event,
) => switch ((state, event)) {
  (PreparationStatus.active, PreparationEvent.revoke) =>
    PreparationStatus.revoked,
  (PreparationStatus.active, PreparationEvent.dispose) =>
    PreparationStatus.disposed,
  (PreparationStatus.revoked, PreparationEvent.revoke) =>
    PreparationStatus.revoked,
  (PreparationStatus.revoked, PreparationEvent.dispose) =>
    PreparationStatus.disposed,
  _ => null,
};
