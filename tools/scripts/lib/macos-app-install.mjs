export function replaceInstalledAppWithRollback({
  stagedPath,
  installedPath,
  backupPath,
  operations,
}) {
  const hadExistingInstall = operations.exists(installedPath);
  if (operations.exists(backupPath)) {
    throw new Error("audit_installed_artifact_mismatch");
  }
  if (hadExistingInstall) operations.rename(installedPath, backupPath);
  try {
    operations.rename(stagedPath, installedPath);
    if (!operations.verify(installedPath)) {
      throw new Error("audit_installed_artifact_mismatch");
    }
  } catch (error) {
    operations.remove(installedPath);
    if (hadExistingInstall && operations.exists(backupPath)) {
      operations.rename(backupPath, installedPath);
    }
    throw error;
  }
  operations.remove(backupPath);
}
