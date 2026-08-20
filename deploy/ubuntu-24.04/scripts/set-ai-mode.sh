#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly SETTINGS_FILE="/srv/stirling-pdf/config/settings.yml"

[ "$(id -u)" -eq 0 ] || {
  echo "run this script as root" >&2
  exit 1
}

case "${1:-}" in
  enable) enabled="true" ;;
  disable) enabled="false" ;;
  *)
    echo "usage: set-ai-mode.sh enable|disable" >&2
    exit 2
    ;;
esac

[ -f "$SETTINGS_FILE" ] || {
  echo "settings file not found: $SETTINGS_FILE" >&2
  exit 1
}

temporary="$(mktemp)"
trap 'rm -f "$temporary"' EXIT

awk -v enabled="$enabled" '
  /^aiEngine:[[:space:]]*$/ { in_ai = 1; found_section = 1; print; next }
  in_ai && /^[^[:space:]#]/ { in_ai = 0 }
  in_ai && /^  enabled:/ {
    print "  enabled: " enabled
    found_enabled = 1
    next
  }
  in_ai && /^  url:/ {
    print "  url: http://stirling-engine:5001"
    found_url = 1
    next
  }
  { print }
  END {
    if (!found_section || !found_enabled || !found_url) {
      exit 3
    }
  }
' "$SETTINGS_FILE" >"$temporary" || {
  echo "aiEngine.enabled/url not found in $SETTINGS_FILE" >&2
  exit 1
}

owner="$(stat -c '%u:%g' "$SETTINGS_FILE")"
mode="$(stat -c '%a' "$SETTINGS_FILE")"
install -o "${owner%:*}" -g "${owner#*:}" -m "$mode" "$temporary" "$SETTINGS_FILE"
