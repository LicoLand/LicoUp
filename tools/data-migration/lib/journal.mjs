import path from "node:path";
import {
  ensureDirectorySync,
  writeJsonAtomicSync,
  readJsonSync,
  removeFileSync,
} from "./fs-atomic.mjs";
import { JOURNAL_SCHEMA } from "./catalog.mjs";

export function journalPath(dataRoot) {
  return path.join(dataRoot, "client-state", "migrations", "data-migration-journal.json");
}

export function openJournal(dataRoot) {
  const file = journalPath(dataRoot);
  return readJsonSync(file);
}

export function initJournal(dataRoot, plan, options = {}) {
  const file = journalPath(dataRoot);
  ensureDirectorySync(path.dirname(file));

  const journal = {
    schemaVersion: JOURNAL_SCHEMA,
    status: "in_progress",
    startedAt: new Date().toISOString(),
    updatedAt: new Date().toISOString(),
    targetVersion: plan.targetVersion,
    targetFrontierId: plan.targetFrontierId,
    direction: plan.direction, // "forward" | "reverse" | "mixed"
    // The operator's statement that every writer is stopped is what makes the
    // offline conversion legitimate; it is recorded with the run.
    maintenanceConfirmedAt: options.maintenanceConfirmedAt ?? null,
    domains: {},
  };

  for (const step of plan.steps) {
    journal.domains[step.domainId] = {
      fromVersion: step.fromVersion,
      toVersion: step.toVersion,
      stepId: step.stepId,
      status: "pending",
      // A step the native owner performs: recorded so a resume keeps the same
      // boundary instead of executing it here.
      deferredTo: step.deferredTo ?? null,
      committedAt: null,
    };
  }

  // Store-format steps are journalled next to the frontier steps but separately:
  // they move the file's published shape, not the domain version the ledger
  // records, and a resume has to be able to tell which of the two stopped.
  journal.storeFormats = {};
  for (const step of plan.storeFormatSteps ?? []) {
    journal.storeFormats[step.domainId] = {
      stepId: step.stepId,
      direction: step.direction,
      fromFormat: step.fromFormat,
      toFormat: step.toFormat,
      status: "pending",
      committedAt: null,
    };
  }

  writeJsonAtomicSync(file, journal);
  return journal;
}

function updateStoreFormat(dataRoot, domainId, mutate) {
  const file = journalPath(dataRoot);
  const journal = readJsonSync(file);
  if (!journal || !journal.storeFormats || !journal.storeFormats[domainId]) return;
  mutate(journal.storeFormats[domainId]);
  journal.updatedAt = new Date().toISOString();
  writeJsonAtomicSync(file, journal);
}

export function markStoreFormatRunning(dataRoot, domainId, stepId) {
  updateStoreFormat(dataRoot, domainId, (entry) => {
    entry.stepId = stepId;
    entry.status = "running";
  });
}

export function markStoreFormatCommitted(dataRoot, domainId, toFormat) {
  updateStoreFormat(dataRoot, domainId, (entry) => {
    entry.status = "committed";
    entry.committedFormat = toFormat;
    entry.committedAt = new Date().toISOString();
  });
}

export function markStoreFormatPending(dataRoot, domainId, reason) {
  updateStoreFormat(dataRoot, domainId, (entry) => {
    entry.status = "pending";
    entry.pendingReason = reason;
  });
}

export function markStepRunning(dataRoot, domainId, stepId) {
  const file = journalPath(dataRoot);
  const journal = readJsonSync(file);
  if (!journal) return;
  if (!journal.domains[domainId]) {
    journal.domains[domainId] = { stepId, status: "running" };
  } else {
    journal.domains[domainId].status = "running";
  }
  journal.updatedAt = new Date().toISOString();
  writeJsonAtomicSync(file, journal);
}

export function markStepPending(dataRoot, domainId, reason) {
  const file = journalPath(dataRoot);
  const journal = readJsonSync(file);
  if (!journal) return;
  if (journal.domains[domainId]) {
    journal.domains[domainId].status = "pending";
    journal.domains[domainId].pendingReason = reason;
  }
  journal.updatedAt = new Date().toISOString();
  writeJsonAtomicSync(file, journal);
}

export function markStepCommitted(dataRoot, domainId, toVersion) {
  const file = journalPath(dataRoot);
  const journal = readJsonSync(file);
  if (!journal) return;
  if (journal.domains[domainId]) {
    journal.domains[domainId].status = "committed";
    journal.domains[domainId].committedVersion = toVersion;
    journal.domains[domainId].committedAt = new Date().toISOString();
  }
  journal.updatedAt = new Date().toISOString();
  writeJsonAtomicSync(file, journal);
}

export function finishJournal(dataRoot) {
  const file = journalPath(dataRoot);
  removeFileSync(file);
}
