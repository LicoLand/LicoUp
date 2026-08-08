#!/bin/sh
set -euo pipefail

APP_PATH="${TARGET_BUILD_DIR:?}/${WRAPPER_NAME:?}"
if [ ! -d "$APP_PATH" ]; then
  echo "iOS app bundle is unavailable for permission normalization." >&2
  exit 1
fi

# Xcode and Flutter may preserve group-writable bits from shared SDK caches.
# Normalize only regular files and directories, never following bundle symlinks.
/usr/bin/find -P "$APP_PATH" -type d -exec /bin/chmod go-w {} +
/usr/bin/find -P "$APP_PATH" -type f -exec /bin/chmod go-w {} +
