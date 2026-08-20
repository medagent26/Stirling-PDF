#!/usr/bin/env bash
set -Eeuo pipefail

readonly DEPLOY_ROOT="/opt/stirling-pdf"
readonly DATA_ROOT="/srv/stirling-pdf"
readonly STIRLING_USER="stirlingpdf"
readonly STIRLING_UID="10001"
readonly STIRLING_GID="10001"
readonly SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly BUNDLE_DIR="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

die() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_root() {
  [ "$(id -u)" -eq 0 ] || die "run this script as root"
}

check_host() {
  # shellcheck source=/dev/null
  . /etc/os-release
  [ "${ID:-}" = "ubuntu" ] || die "Ubuntu is required"
  [ "${VERSION_ID:-}" = "24.04" ] || die "Ubuntu 24.04 is required"
  case "$(dpkg --print-architecture)" in
    amd64 | arm64) ;;
    *) die "only amd64 and arm64 are supported" ;;
  esac

  printf '%s\n' "--- host preflight ---"
  lscpu | sed -n 's/^Architecture:[[:space:]]*/architecture: /p; s/^CPU(s):[[:space:]]*/cpus: /p' | head -2
  free -h | sed -n '1,2p'
  df -h / | sed -n '1,2p'
  if command -v ufw >/dev/null 2>&1; then
    ufw status verbose || true
  fi
  if command -v tailscale >/dev/null 2>&1; then
    tailscale status || true
  else
    printf '%s\n' "tailscale: not installed"
  fi

  [ "$(nproc)" -ge 2 ] || die "at least 2 CPUs are required"
  [ "$(awk '/MemTotal/ {print $2}' /proc/meminfo)" -ge 8000000 ] ||
    die "at least 8 GiB RAM is required for this profile"
  [ "$(df --output=avail -B1 / | tail -1)" -ge 30000000000 ] ||
    die "at least 30 GB free disk is required"
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get install -y ca-certificates curl gnupg age jq openssl

  if ! command -v docker >/dev/null 2>&1; then
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      -o /etc/apt/keyrings/docker.asc
    chmod 0644 /etc/apt/keyrings/docker.asc
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu %s stable\n' \
      "$(dpkg --print-architecture)" "$VERSION_CODENAME" \
      >/etc/apt/sources.list.d/docker.list
    apt-get update
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi
  docker compose version >/dev/null

  if ! command -v tailscale >/dev/null 2>&1; then
    curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.noarmor.gpg \
      -o /usr/share/keyrings/tailscale-archive-keyring.gpg
    curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/noble.tailscale-keyring.list \
      -o /etc/apt/sources.list.d/tailscale.list
    apt-get update
    apt-get install -y tailscale
  fi
}

create_user_and_directories() {
  if ! getent group "$STIRLING_GID" >/dev/null; then
    groupadd --system --gid "$STIRLING_GID" "$STIRLING_USER"
  elif ! getent group "$STIRLING_USER" >/dev/null; then
    die "GID ${STIRLING_GID} is already assigned to another group"
  fi

  if ! getent passwd "$STIRLING_UID" >/dev/null; then
    useradd --system --uid "$STIRLING_UID" --gid "$STIRLING_GID" \
      --home-dir "$DATA_ROOT" --no-create-home --shell /usr/sbin/nologin "$STIRLING_USER"
  elif ! id "$STIRLING_USER" >/dev/null 2>&1; then
    die "UID ${STIRLING_UID} is already assigned to another user"
  fi

  install -d -o root -g root -m 0750 "$DEPLOY_ROOT" "$DEPLOY_ROOT/bin"
  install -d -o root -g root -m 0700 "$DATA_ROOT/backups"
  install -d -o root -g root -m 0755 "$DATA_ROOT/tessdata"
  for path in config logs customFiles pipeline storage engine-data; do
    install -d -o "$STIRLING_UID" -g "$STIRLING_GID" -m 0750 "$DATA_ROOT/$path"
  done
  install -d -o "$STIRLING_UID" -g "$STIRLING_GID" -m 0750 \
    "$DATA_ROOT/config/heap_dumps" \
    "$DATA_ROOT/pipeline/watchedFolders" \
    "$DATA_ROOT/pipeline/finishedFolders"
}

install_ocr_languages() {
  local base_url="https://raw.githubusercontent.com/tesseract-ocr/tessdata_fast/4.1.0"
  local name expected temporary
  while read -r name expected; do
    temporary="$(mktemp)"
    curl -fsSL --retry 3 "${base_url}/${name}.traineddata" -o "$temporary"
    printf '%s  %s\n' "$expected" "$temporary" | sha256sum --check --status ||
      die "checksum failed for ${name}.traineddata"
    install -o root -g root -m 0644 "$temporary" "$DATA_ROOT/tessdata/${name}.traineddata"
    rm -f "$temporary"
  done <<'EOF'
eng 7d4322bd2a7749724879683fc3912cb542f19906c83bcc1a52132556427170b2
nor 0451eb4f8049ae78196806bf878a389a2f40f1386fe038568cf4441226ba6ef2
osd 9cf5d576fcc47564f11265841e5ca839001e7e6f38ff7f7aacf46d15a96b00ff
EOF
}

set_env_value() {
  local file="$1" key="$2" value="$3" temporary
  temporary="$(mktemp)"
  awk -v key="$key" -v value="$value" '
    BEGIN { found = 0 }
    index($0, key "=") == 1 { print key "=" value; found = 1; next }
    { print }
    END { if (!found) print key "=" value }
  ' "$file" >"$temporary"
  install -o root -g root -m 0600 "$temporary" "$file"
  rm -f "$temporary"
}

install_configuration() {
  local public_url="${STIRLING_PUBLIC_URL:-}"
  [[ "$public_url" =~ ^https://[A-Za-z0-9.-]+\.ts\.net$ ]] ||
    die "set STIRLING_PUBLIC_URL to the Tailscale HTTPS origin (*.ts.net)"

  install -o root -g root -m 0644 "$BUNDLE_DIR/compose.yml" "$DEPLOY_ROOT/compose.yml"
  install -o root -g root -m 0644 "$BUNDLE_DIR/compose.ai.yml" "$DEPLOY_ROOT/compose.ai.yml"
  install -o "$STIRLING_UID" -g "$STIRLING_GID" -m 0640 \
    "$BUNDLE_DIR/settings.yml" "$DATA_ROOT/config/settings.yml"
  install -o root -g root -m 0750 "$BUNDLE_DIR/scripts/backup.sh" "$DEPLOY_ROOT/bin/backup.sh"
  install -o root -g root -m 0750 "$BUNDLE_DIR/scripts/restore-backup.sh" "$DEPLOY_ROOT/bin/restore-backup.sh"
  install -o root -g root -m 0750 "$BUNDLE_DIR/scripts/smoke-test.sh" "$DEPLOY_ROOT/bin/smoke-test.sh"

  if [ ! -e "$DEPLOY_ROOT/.env" ]; then
    install -o root -g root -m 0600 "$BUNDLE_DIR/.env.example" "$DEPLOY_ROOT/.env"
    set_env_value "$DEPLOY_ROOT/.env" STIRLING_PUBLIC_URL "$public_url"
    set_env_value "$DEPLOY_ROOT/.env" SECURITY_INITIALLOGIN_PASSWORD "$(openssl rand -hex 24)"
    set_env_value "$DEPLOY_ROOT/.env" STIRLING_ENGINE_SHARED_SECRET "$(openssl rand -hex 32)"
  fi

  install -o root -g root -m 0644 \
    "$BUNDLE_DIR/systemd/stirling-pdf.service" /etc/systemd/system/stirling-pdf.service
  install -o root -g root -m 0644 \
    "$BUNDLE_DIR/systemd/stirling-pdf-backup.service" /etc/systemd/system/stirling-pdf-backup.service
  install -o root -g root -m 0644 \
    "$BUNDLE_DIR/systemd/stirling-pdf-backup.timer" /etc/systemd/system/stirling-pdf-backup.timer
  install -o root -g root -m 0644 \
    "$BUNDLE_DIR/logrotate/stirling-pdf" /etc/logrotate.d/stirling-pdf

  (
    cd "$DEPLOY_ROOT"
    docker compose --env-file .env -f compose.yml config --quiet
    docker compose --env-file .env -f compose.yml pull
  )
}

start_services() {
  systemctl daemon-reload
  systemctl enable --now docker tailscaled stirling-pdf.service stirling-pdf-backup.timer
  if tailscale status --json 2>/dev/null | jq -e '.BackendState == "Running"' >/dev/null; then
    tailscale serve --yes --bg --https=443 http://127.0.0.1:8080
    tailscale serve status
  else
    printf '%s\n' \
      "Tailscale is installed but not connected." \
      "Run 'tailscale up', enable MagicDNS/HTTPS, then:" \
      "  tailscale serve --yes --bg --https=443 http://127.0.0.1:8080"
  fi
}

main() {
  require_root
  check_host
  install_packages
  create_user_and_directories
  install_ocr_languages
  install_configuration
  start_services
  printf '%s\n' \
    "Deployment installed. The bootstrap password is in ${DEPLOY_ROOT}/.env (mode 0600)." \
    "Change it on first login, then remove SECURITY_INITIALLOGIN_PASSWORD from that file."
}

main "$@"
