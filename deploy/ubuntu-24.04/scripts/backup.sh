#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly DEPLOY_ROOT="/opt/stirling-pdf"
readonly DATA_ROOT="/srv/stirling-pdf"
readonly BACKUP_ROOT="${DATA_ROOT}/backups"
readonly ENV_FILE="${DEPLOY_ROOT}/.env"

get_env_value() {
  sed -n "s/^${1}=//p" "$ENV_FILE" | tail -1
}

[ "$(id -u)" -eq 0 ] || {
  echo "backup must run as root" >&2
  exit 1
}
command -v age >/dev/null || {
  echo "age is required" >&2
  exit 1
}

recipient="$(get_env_value BACKUP_AGE_RECIPIENT)"
retention_days="$(get_env_value BACKUP_RETENTION_DAYS)"
[[ "$recipient" == age1* ]] || {
  echo "set a valid BACKUP_AGE_RECIPIENT in ${ENV_FILE}" >&2
  exit 1
}
[[ "${retention_days:-}" =~ ^[0-9]+$ ]] || retention_days=30

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
partial="${BACKUP_ROOT}/stirling-pdf-${timestamp}.tar.gz.age.partial"
output="${partial%.partial}"
mkdir -p "$BACKUP_ROOT"

mapfile -t running_containers < <(
  docker ps --filter label=com.docker.compose.project=stirling-pdf --format '{{.ID}}'
)
restart_containers() {
  rm -f "$partial"
  if [ "${#running_containers[@]}" -gt 0 ]; then
    docker start "${running_containers[@]}" >/dev/null
  fi
}
trap restart_containers EXIT

if [ "${#running_containers[@]}" -gt 0 ]; then
  docker stop --time 120 "${running_containers[@]}" >/dev/null
fi

tar -C "$DATA_ROOT" -czf - \
  config customFiles pipeline storage tessdata engine-data |
  age --encrypt --recipient "$recipient" --output "$partial"
mv "$partial" "$output"
sha256sum "$output" >"${output}.sha256"

if [ "${#running_containers[@]}" -gt 0 ]; then
  docker start "${running_containers[@]}" >/dev/null
  running_containers=()
fi
trap - EXIT

find "$BACKUP_ROOT" -type f \
  \( -name 'stirling-pdf-*.tar.gz.age' -o -name 'stirling-pdf-*.tar.gz.age.sha256' \) \
  -mtime "+${retention_days}" -delete
printf '%s\n' "$output"
