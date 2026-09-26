// GENERATED CODE - DO NOT EDIT.
// Source: apps/desktop/resources/state-machines/secure-mesh.json
// Refresh with tools/development/compile-dart-machines.mjs.

import 'package:licoup/src/contracts/generated/secure_mesh.g.dart';

enum SecureMeshFileSyncEvent {
  beginEvaluation,
  policyAccepted,
  confirm,
  reject,
  fail,
}

const SecureMeshFileSyncStatus secureMeshFileSyncStatusInitial =
    SecureMeshFileSyncStatus.drafting;

bool secureMeshFileSyncStatusIsTerminal(SecureMeshFileSyncStatus state) =>
    switch (state) {
      _ => false,
    };

String secureMeshFileSyncStatusId(SecureMeshFileSyncStatus state) =>
    switch (state) {
      SecureMeshFileSyncStatus.drafting => 'drafting',
      SecureMeshFileSyncStatus.evaluating => 'evaluating',
      SecureMeshFileSyncStatus.awaitingConfirmation => 'awaiting-confirmation',
      SecureMeshFileSyncStatus.confirmed => 'confirmed',
      SecureMeshFileSyncStatus.rejected => 'rejected',
      SecureMeshFileSyncStatus.failed => 'failed',
    };

SecureMeshFileSyncStatus? secureMeshFileSyncStatusFromId(String id) =>
    switch (id.trim().toLowerCase()) {
      'drafting' => SecureMeshFileSyncStatus.drafting,
      'evaluating' => SecureMeshFileSyncStatus.evaluating,
      'awaiting-confirmation' => SecureMeshFileSyncStatus.awaitingConfirmation,
      'confirmed' => SecureMeshFileSyncStatus.confirmed,
      'rejected' => SecureMeshFileSyncStatus.rejected,
      'failed' => SecureMeshFileSyncStatus.failed,
      _ => null,
    };

String secureMeshFileSyncEventId(SecureMeshFileSyncEvent event) =>
    switch (event) {
      SecureMeshFileSyncEvent.beginEvaluation => 'begin-evaluation',
      SecureMeshFileSyncEvent.policyAccepted => 'policy-accepted',
      SecureMeshFileSyncEvent.confirm => 'confirm',
      SecureMeshFileSyncEvent.reject => 'reject',
      SecureMeshFileSyncEvent.fail => 'fail',
    };

SecureMeshFileSyncEvent? secureMeshFileSyncEventFromId(String id) =>
    switch (id.trim().toLowerCase()) {
      'begin-evaluation' => SecureMeshFileSyncEvent.beginEvaluation,
      'policy-accepted' => SecureMeshFileSyncEvent.policyAccepted,
      'confirm' => SecureMeshFileSyncEvent.confirm,
      'reject' => SecureMeshFileSyncEvent.reject,
      'fail' => SecureMeshFileSyncEvent.fail,
      _ => null,
    };

SecureMeshFileSyncStatus? transitionSecureMeshFileSyncStatus(
  SecureMeshFileSyncStatus state,
  SecureMeshFileSyncEvent event,
) => switch ((state, event)) {
  (
    SecureMeshFileSyncStatus.drafting,
    SecureMeshFileSyncEvent.beginEvaluation,
  ) =>
    SecureMeshFileSyncStatus.evaluating,
  (
    SecureMeshFileSyncStatus.evaluating,
    SecureMeshFileSyncEvent.beginEvaluation,
  ) =>
    SecureMeshFileSyncStatus.evaluating,
  (
    SecureMeshFileSyncStatus.awaitingConfirmation,
    SecureMeshFileSyncEvent.beginEvaluation,
  ) =>
    SecureMeshFileSyncStatus.evaluating,
  (
    SecureMeshFileSyncStatus.confirmed,
    SecureMeshFileSyncEvent.beginEvaluation,
  ) =>
    SecureMeshFileSyncStatus.evaluating,
  (
    SecureMeshFileSyncStatus.rejected,
    SecureMeshFileSyncEvent.beginEvaluation,
  ) =>
    SecureMeshFileSyncStatus.evaluating,
  (SecureMeshFileSyncStatus.failed, SecureMeshFileSyncEvent.beginEvaluation) =>
    SecureMeshFileSyncStatus.evaluating,
  (
    SecureMeshFileSyncStatus.evaluating,
    SecureMeshFileSyncEvent.policyAccepted,
  ) =>
    SecureMeshFileSyncStatus.awaitingConfirmation,
  (SecureMeshFileSyncStatus.evaluating, SecureMeshFileSyncEvent.fail) =>
    SecureMeshFileSyncStatus.failed,
  (
    SecureMeshFileSyncStatus.awaitingConfirmation,
    SecureMeshFileSyncEvent.confirm,
  ) =>
    SecureMeshFileSyncStatus.confirmed,
  (
    SecureMeshFileSyncStatus.awaitingConfirmation,
    SecureMeshFileSyncEvent.reject,
  ) =>
    SecureMeshFileSyncStatus.rejected,
  (
    SecureMeshFileSyncStatus.awaitingConfirmation,
    SecureMeshFileSyncEvent.fail,
  ) =>
    SecureMeshFileSyncStatus.failed,
  _ => null,
};

enum SecureMeshApprovalEvent { resolve }

const SecureMeshApprovalStatus secureMeshApprovalStatusInitial =
    SecureMeshApprovalStatus.pending;

bool secureMeshApprovalStatusIsTerminal(SecureMeshApprovalStatus state) =>
    switch (state) {
      SecureMeshApprovalStatus.resolved => true,
      SecureMeshApprovalStatus.expired => true,
      SecureMeshApprovalStatus.failed => true,
      _ => false,
    };

String secureMeshApprovalStatusId(SecureMeshApprovalStatus state) =>
    switch (state) {
      SecureMeshApprovalStatus.pending => 'pending',
      SecureMeshApprovalStatus.resolved => 'resolved',
      SecureMeshApprovalStatus.expired => 'expired',
      SecureMeshApprovalStatus.failed => 'failed',
    };

SecureMeshApprovalStatus? secureMeshApprovalStatusFromId(String id) =>
    switch (id.trim().toLowerCase()) {
      'pending' => SecureMeshApprovalStatus.pending,
      'resolved' => SecureMeshApprovalStatus.resolved,
      'expired' => SecureMeshApprovalStatus.expired,
      'failed' => SecureMeshApprovalStatus.failed,
      _ => null,
    };

String secureMeshApprovalEventId(SecureMeshApprovalEvent event) =>
    switch (event) {
      SecureMeshApprovalEvent.resolve => 'resolve',
    };

SecureMeshApprovalEvent? secureMeshApprovalEventFromId(String id) =>
    switch (id.trim().toLowerCase()) {
      'resolve' => SecureMeshApprovalEvent.resolve,
      _ => null,
    };

SecureMeshApprovalStatus? transitionSecureMeshApprovalStatus(
  SecureMeshApprovalStatus state,
  SecureMeshApprovalEvent event,
) => switch ((state, event)) {
  (SecureMeshApprovalStatus.pending, SecureMeshApprovalEvent.resolve) =>
    SecureMeshApprovalStatus.resolved,
  _ => null,
};
