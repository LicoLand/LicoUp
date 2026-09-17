import path from "node:path";
import fs from "node:fs";
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

export function initJournal(dataRoot, plan) {
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
    domains: {},
  };

  for (const step of plan.steps) {
    journal.domains[step.domainId] = {
      fromVersion: step.fromVersion,
      toVersion: step.toVersion,
      stepId: step.stepId,
      status: "pending",
      committedAt: null,
    };
  }

  writeJsonAtomicSync(file, journal);
  return journal;
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
