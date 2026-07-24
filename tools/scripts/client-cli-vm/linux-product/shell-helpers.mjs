export function linuxProductOwnerOnlyDirectoryFunction() {
  const checks = [
    'directory="$1"',
    'test ! -L "$directory"',
    'install -d -m 0700 "$directory"',
    'test -d "$directory"',
    'test ! -L "$directory"',
    'test "$(stat -c \'%u\' "$directory")" = "$(id -u)"',
    'test "$(stat -c \'%a\' "$directory")" = 700',
  ].join(" && ");
  return `lico_owner_only_directory() { ${checks}; }`;
}

export function linuxProductReportRootPreparationCommand() {
  return [
    'test ! -L "$LICO_VM_PRODUCT_ROOT"',
    'rm -rf "$LICO_VM_PRODUCT_ROOT"',
    'test ! -L "$LICO_LINUX_VM_REPORT_ROOT"',
    'rm -rf "$LICO_LINUX_VM_REPORT_ROOT"',
    'lico_owner_only_directory "$LICO_VM_PRODUCT_ROOT"',
    'lico_owner_only_directory "$LICO_LINUX_VM_REPORT_ROOT"',
  ].join(" && ");
}

export function linuxProductDistributionReportTreePreparationCommand() {
  return [
    "$HOME/lico-up/build",
    "$HOME/lico-up/build/apps",
    "$HOME/lico-up/build/apps/desktop",
    "$HOME/lico-up/build/apps/desktop/distribution",
    "$HOME/lico-up/build/apps/desktop/distribution/linux-arm64",
  ]
    .map((directory) => `lico_owner_only_directory "${directory}"`)
    .join(" && ");
}
