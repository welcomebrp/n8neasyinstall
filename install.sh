#!/usr/bin/env bash
# Production-oriented n8n installer for a fresh Ubuntu VPS.
# Installs Docker Engine + Compose, PostgreSQL, n8n, external task runner,
# and Caddy with automatic HTTPS.
#
# Usage:
#   chmod +x install-n8n-ubuntu.sh
#   sudo ./install-n8n-ubuntu.sh

set -Eeuo pipefail
IFS=$'\n\t'

INSTALL_DIR="/opt/n8n"
FALLBACK_N8N_VERSION="2.36.7"
DEFAULT_TIMEZONE="Asia/Kathmandu"

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m✓ %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33mWARNING: %s\033[0m\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

on_error() {
  local exit_code=$?
  printf '\n\033[1;31mInstallation failed on line %s (exit code %s).\033[0m\n' "${BASH_LINENO[0]:-unknown}" "$exit_code" >&2
  printf 'If Docker Compose was already created, inspect logs with:\n  cd %s && docker compose logs --tail=200\n' "$INSTALL_DIR" >&2
  exit "$exit_code"
}
trap on_error ERR

# Re-run through sudo if needed.
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  if command -v sudo >/dev/null 2>&1; then
    exec sudo -E bash "$0" "$@"
  fi
  die "Run this script as root (or install sudo)."
fi

[[ -r /etc/os-release ]] || die "Cannot detect operating system."
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || die "This installer supports Ubuntu only. Detected: ${PRETTY_NAME:-unknown}."

printf '\n============================================================\n'
printf '             n8n Ubuntu VPS Installer\n'
printf '============================================================\n'
printf 'This will install n8n + PostgreSQL + Caddy (HTTPS).\n'
printf 'Recommended: a fresh Ubuntu 22.04/24.04/26.04 VPS.\n\n'

# -------- Interactive inputs --------
while true; do
  read -r -p "Full n8n domain (example: n8n.example.com): " N8N_DOMAIN
  N8N_DOMAIN="${N8N_DOMAIN#http://}"
  N8N_DOMAIN="${N8N_DOMAIN#https://}"
  N8N_DOMAIN="${N8N_DOMAIN%/}"
  N8N_DOMAIN="$(printf '%s' "$N8N_DOMAIN" | tr '[:upper:]' '[:lower:]')"

  if [[ "$N8N_DOMAIN" =~ ^([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
    break
  fi
  warn "Enter only a valid hostname, for example: n8n.example.com"
done

while true; do
  read -r -p "Email for Let's Encrypt / SSL notices: " SSL_EMAIL
  if [[ "$SSL_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]]; then
    break
  fi
  warn "Please enter a valid email address."
done

read -r -p "Timezone [${DEFAULT_TIMEZONE}]: " GENERIC_TIMEZONE
GENERIC_TIMEZONE="${GENERIC_TIMEZONE:-$DEFAULT_TIMEZONE}"
if [[ ! "$GENERIC_TIMEZONE" =~ ^[A-Za-z0-9._+-]+(/[A-Za-z0-9._+-]+)*$ ]] || [[ ! -f "/usr/share/zoneinfo/${GENERIC_TIMEZONE}" ]]; then
  die "Invalid timezone: ${GENERIC_TIMEZONE}. Example: Asia/Kathmandu, UTC, Europe/London"
fi

if [[ -e "$INSTALL_DIR/compose.yml" || -e "$INSTALL_DIR/docker-compose.yml" || -e "$INSTALL_DIR/.env" ]]; then
  die "An existing n8n configuration was found in ${INSTALL_DIR}. This script will not overwrite it. Back it up/move it first."
fi

log "Updating Ubuntu packages and installing prerequisites"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y ca-certificates curl openssl ufw dnsutils jq

# -------- Docker --------
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  ok "Docker and Docker Compose already installed; reusing them."
else
  log "Configuring Docker's official Ubuntu repository"

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc

  cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF

  apt-get update

  if command -v docker >/dev/null 2>&1; then
    warn "An existing Docker installation was found, but Docker Compose v2 is missing."
    apt-get install -y docker-compose-plugin || die "Could not add Docker Compose safely. Install Docker Compose v2, then rerun the script."
  else
    log "Installing Docker Engine"
    # On a fresh machine, remove packages that conflict with Docker CE.
    for pkg in docker.io docker-compose docker-compose-v2 docker-doc docker-buildx podman-docker containerd runc; do
      apt-get remove -y "$pkg" >/dev/null 2>&1 || true
    done
    apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  fi
fi

systemctl enable --now docker
docker info >/dev/null
docker compose version
ok "Docker is running."

# -------- Firewall --------
log "Configuring firewall"
SSH_PORT="22"
if [[ -n "${SSH_CONNECTION:-}" ]]; then
  detected_ssh_port="$(awk '{print $4}' <<<"$SSH_CONNECTION")"
  if [[ "$detected_ssh_port" =~ ^[0-9]+$ ]] && (( detected_ssh_port >= 1 && detected_ssh_port <= 65535 )); then
    SSH_PORT="$detected_ssh_port"
  fi
fi

ufw allow "${SSH_PORT}/tcp" comment 'SSH' >/dev/null
ufw allow 80/tcp comment 'HTTP for Caddy' >/dev/null
ufw allow 443/tcp comment 'HTTPS for Caddy' >/dev/null
ufw allow 443/udp comment 'HTTP3 for Caddy' >/dev/null
ufw --force enable >/dev/null
ok "UFW enabled; SSH ${SSH_PORT}/tcp, HTTP 80, HTTPS 443 allowed."

# -------- Port check --------
if ss -ltnp 2>/dev/null | grep -Eq ':(80|443)[[:space:]]'; then
  printf '\nProcesses currently using port 80/443:\n' >&2
  ss -ltnp 2>/dev/null | grep -E ':(80|443)[[:space:]]' >&2 || true
  die "Port 80 or 443 is already in use. Stop the existing web server/reverse proxy, then run this installer again."
fi

# -------- Resolve current stable n8n version --------
log "Resolving the current stable n8n release"
N8N_VERSION=""
if N8N_DIST_TAGS="$(curl -fsSL --max-time 15 https://registry.npmjs.org/-/package/n8n/dist-tags 2>/dev/null)"; then
  N8N_VERSION="$(jq -r '.stable // .latest // empty' <<<"$N8N_DIST_TAGS")"
fi
if [[ ! "$N8N_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]]; then
  warn "Could not resolve the stable n8n version from npm. Falling back to ${FALLBACK_N8N_VERSION}."
  N8N_VERSION="$FALLBACK_N8N_VERSION"
fi
ok "n8n version selected: ${N8N_VERSION}"

# -------- DNS information --------
log "Checking DNS"
SERVER_IPV4="$(curl -4 -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)"
DOMAIN_IPV4S="$(dig +short A "$N8N_DOMAIN" 2>/dev/null | grep -E '^[0-9]+(\.[0-9]+){3}$' | sort -u | paste -sd, - || true)"
DOMAIN_IPV6S="$(dig +short AAAA "$N8N_DOMAIN" 2>/dev/null | sort -u | paste -sd, - || true)"

if [[ -n "$SERVER_IPV4" ]]; then
  printf 'Server public IPv4: %s\n' "$SERVER_IPV4"
fi
if [[ -n "$DOMAIN_IPV4S" ]]; then
  printf '%s currently resolves (A) to: %s\n' "$N8N_DOMAIN" "$DOMAIN_IPV4S"
else
  warn "No A record currently resolves for ${N8N_DOMAIN}."
fi
if [[ -n "$DOMAIN_IPV6S" ]]; then
  printf '%s currently resolves (AAAA) to: %s\n' "$N8N_DOMAIN" "$DOMAIN_IPV6S"
fi
if [[ -n "$SERVER_IPV4" && -n "$DOMAIN_IPV4S" && ",${DOMAIN_IPV4S}," != *",${SERVER_IPV4},"* ]]; then
  warn "The domain's A record does not directly match this VPS IPv4. This can be normal with a proxy such as Cloudflare; otherwise fix DNS."
fi

# -------- Generate secrets and configuration --------
log "Creating n8n configuration in ${INSTALL_DIR}"
mkdir -p "$INSTALL_DIR/local-files"
chmod 750 "$INSTALL_DIR"
chown 1000:1000 "$INSTALL_DIR/local-files" || true
chmod 750 "$INSTALL_DIR/local-files"

POSTGRES_PASSWORD="$(openssl rand -hex 32)"
POSTGRES_NON_ROOT_PASSWORD="$(openssl rand -hex 32)"
ENCRYPTION_KEY="$(openssl rand -hex 32)"
RUNNERS_AUTH_TOKEN="$(openssl rand -hex 32)"

cat > "$INSTALL_DIR/.env" <<EOF
# Generated by install-n8n-ubuntu.sh
N8N_VERSION=${N8N_VERSION}
N8N_DOMAIN=${N8N_DOMAIN}
GENERIC_TIMEZONE=${GENERIC_TIMEZONE}

POSTGRES_USER=postgres
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_DB=n8n
POSTGRES_NON_ROOT_USER=n8n
POSTGRES_NON_ROOT_PASSWORD=${POSTGRES_NON_ROOT_PASSWORD}

N8N_ENCRYPTION_KEY=${ENCRYPTION_KEY}
RUNNERS_AUTH_TOKEN=${RUNNERS_AUTH_TOKEN}
EOF
chmod 600 "$INSTALL_DIR/.env"

# Based on n8n's official withPostgres init-data.sh pattern.
cat > "$INSTALL_DIR/init-data.sh" <<'EOF'
#!/bin/bash
set -e

if [ -n "${POSTGRES_NON_ROOT_USER:-}" ] && [ -n "${POSTGRES_NON_ROOT_PASSWORD:-}" ]; then
  psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" <<-EOSQL
    CREATE USER ${POSTGRES_NON_ROOT_USER} WITH PASSWORD '${POSTGRES_NON_ROOT_PASSWORD}';
    GRANT ALL PRIVILEGES ON DATABASE ${POSTGRES_DB} TO ${POSTGRES_NON_ROOT_USER};
    GRANT CREATE ON SCHEMA public TO ${POSTGRES_NON_ROOT_USER};
EOSQL
else
  echo "SETUP INFO: Missing non-root PostgreSQL environment variables."
  exit 1
fi
EOF
chmod 750 "$INSTALL_DIR/init-data.sh"

cat > "$INSTALL_DIR/Caddyfile" <<EOF
{
  email ${SSL_EMAIL}
}

${N8N_DOMAIN} {
  encode zstd gzip

  reverse_proxy n8n:5678 {
    flush_interval -1
  }
}
EOF
chmod 644 "$INSTALL_DIR/Caddyfile"

cat > "$INSTALL_DIR/compose.yml" <<'EOF'
services:
  postgres:
    image: postgres:16-alpine
    restart: unless-stopped
    environment:
      POSTGRES_USER: ${POSTGRES_USER}
      POSTGRES_PASSWORD: ${POSTGRES_PASSWORD}
      POSTGRES_DB: ${POSTGRES_DB}
      POSTGRES_NON_ROOT_USER: ${POSTGRES_NON_ROOT_USER}
      POSTGRES_NON_ROOT_PASSWORD: ${POSTGRES_NON_ROOT_PASSWORD}
    volumes:
      - postgres_data:/var/lib/postgresql/data
      - ./init-data.sh:/docker-entrypoint-initdb.d/init-data.sh:ro
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -h localhost -U ${POSTGRES_USER} -d ${POSTGRES_DB}"]
      interval: 5s
      timeout: 5s
      retries: 10
    networks:
      - backend

  n8n:
    image: docker.n8n.io/n8nio/n8n:${N8N_VERSION}
    restart: unless-stopped
    depends_on:
      postgres:
        condition: service_healthy
    environment:
      DB_TYPE: postgresdb
      DB_POSTGRESDB_HOST: postgres
      DB_POSTGRESDB_PORT: "5432"
      DB_POSTGRESDB_DATABASE: ${POSTGRES_DB}
      DB_POSTGRESDB_USER: ${POSTGRES_NON_ROOT_USER}
      DB_POSTGRESDB_PASSWORD: ${POSTGRES_NON_ROOT_PASSWORD}

      N8N_ENCRYPTION_KEY: ${N8N_ENCRYPTION_KEY}
      GENERIC_TIMEZONE: ${GENERIC_TIMEZONE}
      TZ: ${GENERIC_TIMEZONE}

      N8N_HOST: ${N8N_DOMAIN}
      N8N_PORT: "5678"
      N8N_PROTOCOL: https
      WEBHOOK_URL: https://${N8N_DOMAIN}/
      N8N_EDITOR_BASE_URL: https://${N8N_DOMAIN}/
      N8N_PROXY_HOPS: "1"

      NODE_ENV: production
      N8N_ENFORCE_SETTINGS_FILE_PERMISSIONS: "true"
      N8N_SECURE_COOKIE: "true"
      N8N_RESTRICT_FILE_ACCESS_TO: /files

      N8N_RUNNERS_MODE: external
      N8N_RUNNERS_AUTH_TOKEN: ${RUNNERS_AUTH_TOKEN}
      N8N_RUNNERS_BROKER_LISTEN_ADDRESS: 0.0.0.0
    volumes:
      - n8n_data:/home/node/.n8n
      - ./local-files:/files
    networks:
      - frontend
      - backend

  n8n-runner:
    image: n8nio/runners:${N8N_VERSION}
    restart: unless-stopped
    depends_on:
      - n8n
    environment:
      N8N_RUNNERS_AUTH_TOKEN: ${RUNNERS_AUTH_TOKEN}
      N8N_RUNNERS_TASK_BROKER_URI: http://n8n:5679
    networks:
      - backend
      - runner_egress

  caddy:
    image: caddy:2-alpine
    restart: unless-stopped
    depends_on:
      - n8n
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - caddy_data:/data
      - caddy_config:/config
    networks:
      - frontend

volumes:
  postgres_data:
  n8n_data:
  caddy_data:
  caddy_config:

networks:
  frontend:
  runner_egress:
  backend:
    internal: true
EOF
chmod 640 "$INSTALL_DIR/compose.yml"

# Validate Compose before pulling or starting anything.
cd "$INSTALL_DIR"
docker compose config --quiet
ok "Docker Compose configuration is valid."

# -------- Start services --------
log "Pulling images and starting n8n"
docker compose pull
docker compose up -d

log "Container status"
docker compose ps

# Give services a short startup window and report obvious failures.
sleep 8
if ! docker compose ps --status running --services | grep -qx 'postgres'; then
  docker compose logs --tail=120 postgres >&2 || true
  die "PostgreSQL did not start successfully."
fi
if ! docker compose ps --status running --services | grep -qx 'n8n'; then
  docker compose logs --tail=160 n8n >&2 || true
  die "n8n did not start successfully."
fi
if ! docker compose ps --status running --services | grep -qx 'caddy'; then
  docker compose logs --tail=120 caddy >&2 || true
  die "Caddy did not start successfully."
fi

# -------- Finish --------
printf '\n============================================================\n'
printf '\033[1;32m          n8n installation completed!\033[0m\n'
printf '============================================================\n\n'
printf 'n8n URL:       https://%s\n' "$N8N_DOMAIN"
printf 'n8n version:   %s\n' "$N8N_VERSION"
printf 'Timezone:      %s\n' "$GENERIC_TIMEZONE"
printf 'Install path:  %s\n\n' "$INSTALL_DIR"

printf 'IMPORTANT:\n'
printf '  1. Ensure DNS for %s points/proxies to this VPS.\n' "$N8N_DOMAIN"
if [[ -n "$SERVER_IPV4" ]]; then
  printf '     VPS IPv4: %s\n' "$SERVER_IPV4"
fi
printf '  2. Open the URL and create the first n8n owner account.\n'
printf '  3. Back up %s/.env and your Docker volumes securely.\n' "$INSTALL_DIR"
printf '  4. Do NOT publish PostgreSQL (5432) or n8n (5678) directly to the Internet.\n\n'

printf 'Useful commands:\n'
printf '  cd %s && docker compose ps\n' "$INSTALL_DIR"
printf '  cd %s && docker compose logs -f n8n\n' "$INSTALL_DIR"
printf '  cd %s && docker compose logs -f caddy\n' "$INSTALL_DIR"
printf '  cd %s && docker compose restart\n\n' "$INSTALL_DIR"

if [[ -z "$DOMAIN_IPV4S" ]]; then
  warn "DNS is not resolving yet. Caddy will keep retrying HTTPS automatically after DNS is fixed."
else
  printf 'If HTTPS is not ready immediately, inspect Caddy logs:\n'
  printf '  cd %s && docker compose logs -f caddy\n\n' "$INSTALL_DIR"
fi

ok "Done."
