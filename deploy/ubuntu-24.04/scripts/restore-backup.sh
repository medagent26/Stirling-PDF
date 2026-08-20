#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

usage() {
  echo "usage: AGE_IDENTITY_FILE=/secure/path/key.txt $0 BACKUP TARGET_DIRECTORY" >&2
  exit 2
}

[ "$#" -eq 2 ] || usage
BACKUP="$(readlink -f "$1")"
readonly BACKUP
readonly TARGET="$2"
readonly IDENTITY="${AGE_IDENTITY_FILE:-}"

[ -f "$BACKUP" ] || {
  echo "backup not found: $BACKUP" >&2
  exit 1
}
[ -f "${BACKUP}.sha256" ] || {
  echo "checksum file not found: ${BACKUP}.sha256" >&2
  exit 1
}
if [ -z "$IDENTITY" ] || [ ! -f "$IDENTITY" ]; then
  echo "AGE_IDENTITY_FILE must point to the offline age identity" >&2
  exit 1
fi
[ "$TARGET" != "/srv/stirling-pdf" ] || {
  echo "restore into a separate directory first; live overwrite is refused" >&2
  exit 1
}
[ ! -e "$TARGET" ] || {
  echo "target already exists: $TARGET" >&2
  exit 1
}

(cd "$(dirname "$BACKUP")" && sha256sum --check "$(basename "${BACKUP}.sha256")")
install -d -o root -g root -m 0700 "$TARGET"
age --decrypt --identity "$IDENTITY" "$BACKUP" | tar -xzf - -C "$TARGET"

for required in config customFiles pipeline storage tessdata engine-data; do
  [ -d "$TARGET/$required" ] || {
    echo "restore is incomplete: missing $required" >&2
    exit 1
  }
done
printf 'Restore verified in %s\n' "$TARGET"
