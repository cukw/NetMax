#!/usr/bin/env bash
set -euo pipefail

# NetMax full deploy script for servers where project path is /root/NetMax.
# Run as root from /root:
#   cd /root
#   bash /root/NetMax/deploy/deploy-from-root.sh
#
# Optional env overrides:
#   CERT_IP=155.212.141.80 CERT_DAYS=825 bash /root/NetMax/deploy/deploy-from-root.sh
#   BUILD_WEB=true bash /root/NetMax/deploy/deploy-from-root.sh

PROJECT_DIR="/root/NetMax"
BACKEND_DIR="${PROJECT_DIR}/backend"
DEPLOY_NGINX_DIR="${PROJECT_DIR}/deploy/nginx"

CERT_DIR="/etc/ssl/netmax"
CERT_FILE="${CERT_DIR}/fullchain.pem"
KEY_FILE="${CERT_DIR}/privkey.pem"
CERT_IP="${CERT_IP:-155.212.141.80}"
CERT_DAYS="${CERT_DAYS:-825}"
BUILD_WEB="${BUILD_WEB:-false}"

NGINX_CONF_SRC="${DEPLOY_NGINX_DIR}/netmax.conf"
NGINX_CONF_DST="/etc/nginx/conf.d/netmax.conf"

BACKEND_ENV_DIR="/etc/netmax"
BACKEND_ENV_FILE="${BACKEND_ENV_DIR}/backend.env"
BACKEND_SERVICE_FILE="/etc/systemd/system/netmax-backend.service"

WEB_DST="/var/www/netmax-web"

log() {
  printf '[deploy] %s\n' "$*"
}

warn() {
  printf '[deploy][warn] %s\n' "$*" >&2
}

die() {
  printf '[deploy][error] %s\n' "$*" >&2
  exit 1
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Script must be run as root."
  fi
}

require_cmd() {
  local cmd="$1"
  command -v "${cmd}" >/dev/null 2>&1 || die "Missing required command: ${cmd}"
}

ensure_paths() {
  [[ -d "${PROJECT_DIR}" ]] || die "Project directory not found: ${PROJECT_DIR}"
  [[ -d "${BACKEND_DIR}" ]] || die "Backend directory not found: ${BACKEND_DIR}"
  [[ -f "${NGINX_CONF_SRC}" ]] || die "Nginx config not found: ${NGINX_CONF_SRC}"
  [[ -f "${DEPLOY_NGINX_DIR}/openssl-selfsigned.cnf" ]] || die "OpenSSL config not found."
}

check_resources() {
  if [[ -r /proc/meminfo ]]; then
    local mem_kb
    mem_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
    if [[ -n "${mem_kb}" && "${mem_kb}" =~ ^[0-9]+$ ]]; then
      if (( mem_kb < 3000000 )); then
        warn "Detected low RAM (${mem_kb} KB)."
        warn "On 2 GB servers Flutter web build often fails with OOM."
        warn "Default BUILD_WEB=false is recommended for this host."
      fi
    fi
  fi
}

install_backend_deps() {
  local dart_bin="$1"
  log "Installing backend dependencies..."
  (
    cd "${BACKEND_DIR}"
    "${dart_bin}" pub get
  )
}

build_web_if_possible() {
  if [[ "${BUILD_WEB}" != "true" ]]; then
    log "Skipping web build (BUILD_WEB=${BUILD_WEB})."
    return
  fi

  if ! command -v flutter >/dev/null 2>&1; then
    warn "flutter not found. Web build step skipped."
    return
  fi

  log "Building Flutter web..."
  (
    cd "${PROJECT_DIR}"
    flutter pub get
    flutter build web --release
  )

  if [[ ! -d "${PROJECT_DIR}/build/web" ]]; then
    warn "Web build output not found at ${PROJECT_DIR}/build/web; skipping web publish."
    return
  fi

  log "Publishing web build to ${WEB_DST}..."
  install -d -m 0755 "${WEB_DST}"
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete "${PROJECT_DIR}/build/web/" "${WEB_DST}/"
  else
    rm -rf "${WEB_DST:?}/"*
    cp -a "${PROJECT_DIR}/build/web/." "${WEB_DST}/"
  fi
}

ensure_self_signed_cert() {
  if [[ -s "${CERT_FILE}" && -s "${KEY_FILE}" ]]; then
    log "TLS certificate already exists. Skipping certificate generation."
    return
  fi

  log "Generating self-signed TLS certificate (IP: ${CERT_IP})..."
  install -d -m 0755 "${CERT_DIR}"

  local tmp_config
  tmp_config="$(mktemp)"
  trap 'rm -f "${tmp_config}"' EXIT

  sed "s/155\\.212\\.141\\.80/${CERT_IP}/g" \
    "${DEPLOY_NGINX_DIR}/openssl-selfsigned.cnf" > "${tmp_config}"

  openssl req -x509 -nodes -newkey rsa:4096 \
    -days "${CERT_DAYS}" \
    -keyout "${KEY_FILE}" \
    -out "${CERT_FILE}" \
    -config "${tmp_config}" \
    -extensions v3_req

  chmod 600 "${KEY_FILE}"
  chmod 644 "${CERT_FILE}"
  log "Self-signed certificate created."
}

ensure_backend_env_file() {
  install -d -m 0755 "${BACKEND_ENV_DIR}"

  if [[ -f "${BACKEND_ENV_FILE}" ]]; then
    log "Backend env file already exists: ${BACKEND_ENV_FILE}"
    return
  fi

  cat > "${BACKEND_ENV_FILE}" <<'EOF'
PORT=8080
NETMAX_BIND_HOST=127.0.0.1
NETMAX_MONGO_URI=mongodb://127.0.0.1:27017/netmax
NETMAX_EMAIL_AUTH_RETURN_DEV_CODE=false
# Optional:
# NETMAX_SMTP_HOST=smtp.example.com
# NETMAX_SMTP_PORT=587
# NETMAX_SMTP_FROM=noreply@example.com
# NETMAX_SMTP_USERNAME=user
# NETMAX_SMTP_PASSWORD=pass
# NETMAX_SMTP_TLS=true
EOF
  chmod 640 "${BACKEND_ENV_FILE}"
  log "Created backend env file: ${BACKEND_ENV_FILE}"
}

write_backend_service() {
  local dart_bin="$1"
  cat > "${BACKEND_SERVICE_FILE}" <<EOF
[Unit]
Description=NetMax Backend Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=${BACKEND_DIR}
EnvironmentFile=-${BACKEND_ENV_FILE}
ExecStart=${dart_bin} run bin/server.dart
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "${BACKEND_SERVICE_FILE}"
  log "Wrote systemd unit: ${BACKEND_SERVICE_FILE}"
}

install_nginx_config() {
  install -D -m 0644 "${NGINX_CONF_SRC}" "${NGINX_CONF_DST}"
  log "Installed Nginx config: ${NGINX_CONF_DST}"
  nginx -t
}

start_mongo_if_present() {
  if systemctl list-unit-files | grep -q '^mongod\.service'; then
    log "Enabling mongod.service..."
    systemctl enable --now mongod.service
    return
  fi
  if systemctl list-unit-files | grep -q '^mongodb\.service'; then
    log "Enabling mongodb.service..."
    systemctl enable --now mongodb.service
    return
  fi
  warn "MongoDB systemd service not found (mongod.service/mongodb.service)."
}

reload_and_start_services() {
  systemctl daemon-reload

  log "Enabling and restarting netmax-backend.service..."
  systemctl enable --now netmax-backend.service
  systemctl restart netmax-backend.service

  log "Enabling and restarting nginx.service..."
  systemctl enable --now nginx.service
  systemctl restart nginx.service
}

health_checks() {
  require_cmd curl
  log "Checking backend health on localhost..."
  curl -fsS "http://127.0.0.1:8080/health" >/dev/null

  log "Checking HTTPS health through Nginx..."
  curl -kfsS "https://127.0.0.1/health" >/dev/null

  systemctl is-active --quiet netmax-backend.service || die "netmax-backend.service is not active."
  systemctl is-active --quiet nginx.service || die "nginx.service is not active."
}

main() {
  require_root

  require_cmd systemctl
  require_cmd openssl
  require_cmd nginx
  require_cmd sed

  local dart_bin
  dart_bin="$(command -v dart || true)"
  [[ -n "${dart_bin}" ]] || die "Dart SDK not found in PATH."

  ensure_paths
  check_resources
  install_backend_deps "${dart_bin}"
  build_web_if_possible
  ensure_self_signed_cert
  ensure_backend_env_file
  write_backend_service "${dart_bin}"
  install_nginx_config
  start_mongo_if_present
  reload_and_start_services
  health_checks

  log "Deploy completed successfully."
  log "Public endpoint: wss://${CERT_IP}/ws"
  log "Note: with self-signed cert, clients must trust the certificate."
}

main "$@"
