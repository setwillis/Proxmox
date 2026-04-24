#!/usr/bin/env bash
# shellcheck shell=bash
# Vaultwarden + PostgreSQL — install script
# Выполняется ВНУТРИ LXC контейнера.
# Не запускать напрямую на хосте Proxmox.

source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/core.func)
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/tools.func)
color; formatting; icons; load_functions; catch_errors

# ------------------------------------------------------------------
# Вспомогательные функции (не зависят от tools.func)
# ------------------------------------------------------------------

PWGEN() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-32}" 2>/dev/null; echo; }

# Получить последний тег релиза с GitHub API
gh_latest_release() {
  local repo="$1"
  curl -fsSL "https://api.github.com/repos/${repo}/releases/latest" \
    | grep '"tag_name"' \
    | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/'
}

# Скачать и распаковать tarball исходников с GitHub
gh_fetch_tarball() {
  local repo="$1"
  local tag="$2"
  local dest="$3"
  local url="https://github.com/${repo}/archive/refs/tags/${tag}.tar.gz"
  mkdir -p "$dest"
  curl -fsSL "$url" | tar -xz -C "$dest" --strip-components=1
}

# Скачать asset релиза по glob-паттерну
gh_fetch_asset() {
  local repo="$1"
  local tag="$2"
  local pattern="$3"
  local dest="$4"
  local download_url
  download_url=$(curl -fsSL "https://api.github.com/repos/${repo}/releases/tags/${tag}" \
    | grep '"browser_download_url"' \
    | grep -i "${pattern//\*/.*}" \
    | head -n1 \
    | sed -E 's/.*"browser_download_url": *"([^"]+)".*/\1/')
  if [[ -z "$download_url" ]]; then
    msg_error "No asset matching '${pattern}' found in ${repo}@${tag}"
    exit 1
  fi
  mkdir -p "$dest"
  curl -fsSL "$download_url" | tar -xz -C "$dest" --strip-components=1
}

# ------------------------------------------------------------------
# Resolve the container's own IP
# ------------------------------------------------------------------
IP=$(hostname -I | awk '{print $1}')

# ------------------------------------------------------------------
# 1. OS packages
# ------------------------------------------------------------------
msg_info "Installing OS packages"
$STD apt-get update
$STD apt-get install -y \
  curl wget sudo mc nano git jq unzip ca-certificates openssl \
  build-essential clang pkg-config libssl-dev cmake \
  postgresql postgresql-contrib postgresql-server-dev-all argon2
msg_ok "OS packages installed"

# ------------------------------------------------------------------
# 2. Rust toolchain
# ------------------------------------------------------------------
msg_info "Installing Rust toolchain"
if ! command -v cargo >/dev/null 2>&1; then
  curl https://sh.rustup.rs -sSf | sh -s -- -y >/dev/null 2>&1
fi
# shellcheck disable=SC1091
source /root/.cargo/env 2>/dev/null || true
msg_ok "Rust toolchain ready"

# ------------------------------------------------------------------
# 3. Service user & directories
# ------------------------------------------------------------------
msg_info "Creating service user and directories"
id -u vaultwarden >/dev/null 2>&1 || \
  useradd --system --home /opt/vaultwarden --shell /usr/sbin/nologin vaultwarden
mkdir -p /opt/vaultwarden/{data,web-vault,backups}
chown -R vaultwarden:vaultwarden /opt/vaultwarden
msg_ok "Service user and directories created"

# ------------------------------------------------------------------
# 4. PostgreSQL
# ------------------------------------------------------------------
msg_info "Configuring PostgreSQL"
PG_DB="vaultwarden"
PG_USER="vaultwarden"
PG_PASS="$(PWGEN 32)"

$STD systemctl enable postgresql
$STD systemctl start postgresql

# Создать роль если не существует
sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='${PG_USER}'" \
  | grep -q 1 \
  || sudo -u postgres psql -c \
       "CREATE USER ${PG_USER} WITH ENCRYPTED PASSWORD '${PG_PASS}';" >/dev/null 2>&1

# Создать БД если не существует
sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='${PG_DB}'" \
  | grep -q 1 \
  || sudo -u postgres psql -c \
       "CREATE DATABASE ${PG_DB} OWNER ${PG_USER};" >/dev/null 2>&1

sudo -u postgres psql -c "ALTER DATABASE ${PG_DB} OWNER TO ${PG_USER};" >/dev/null 2>&1
sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE ${PG_DB} TO ${PG_USER};" >/dev/null 2>&1

# Разрешить TCP-подключение для пользователя vaultwarden
PG_HBA=$(find /etc/postgresql -name pg_hba.conf | head -n1)
if [[ -n "$PG_HBA" ]]; then
  if ! grep -q "^host.*${PG_DB}.*${PG_USER}.*127.0.0.1" "$PG_HBA"; then
    echo "host    ${PG_DB}    ${PG_USER}    127.0.0.1/32    scram-sha-256" >> "$PG_HBA"
    $STD systemctl reload postgresql
  fi
fi
msg_ok "PostgreSQL configured"

# ------------------------------------------------------------------
# 5. Web-Vault
# ------------------------------------------------------------------
WEB_RELEASE=$(gh_latest_release "dani-garcia/bw_web_builds")
msg_info "Downloading Web-Vault ${WEB_RELEASE}"
gh_fetch_asset \
  "dani-garcia/bw_web_builds" \
  "${WEB_RELEASE}" \
  "bw_web_*.tar.gz" \
  "/opt/vaultwarden/web-vault"
chown -R vaultwarden:vaultwarden /opt/vaultwarden/web-vault
msg_ok "Web-Vault ${WEB_RELEASE} downloaded"

# ------------------------------------------------------------------
# 6. Сборка Vaultwarden из исходников
# ------------------------------------------------------------------
VAULT_RELEASE=$(gh_latest_release "dani-garcia/vaultwarden")
msg_info "Building Vaultwarden ${VAULT_RELEASE} (занимает 10-20 минут)"
rm -rf /tmp/vaultwarden-src
gh_fetch_tarball \
  "dani-garcia/vaultwarden" \
  "${VAULT_RELEASE}" \
  "/tmp/vaultwarden-src"

cd /tmp/vaultwarden-src || { msg_error "Source directory missing after fetch"; exit 1; }
VW_VERSION="$VAULT_RELEASE" cargo build --features "postgresql" --release >/dev/null 2>&1
install -m 0755 target/release/vaultwarden /usr/bin/vaultwarden
cd ~
rm -rf /tmp/vaultwarden-src
msg_ok "Vaultwarden ${VAULT_RELEASE} built and installed"

# ------------------------------------------------------------------
# 7. Конфигурационный файл
# ------------------------------------------------------------------
msg_info "Writing configuration"
ADMIN_RAW="$(PWGEN 48)"
ADMIN_HASH=$(echo -n "${ADMIN_RAW}" | argon2 "$(openssl rand -base64 32)" -t 2 -m 16 -p 4 -l 64 -e)

cat >/opt/vaultwarden/.env <<EOF
DATA_FOLDER=/opt/vaultwarden/data
DATABASE_URL=postgresql://${PG_USER}:${PG_PASS}@127.0.0.1:5432/${PG_DB}
DOMAIN=http://${IP}:8000
WEBAUTHN_RP_ID=${IP}
WEBAUTHN_RP_NAME=Vaultwarden
ROCKET_ADDRESS=0.0.0.0
ROCKET_PORT=8000
SIGNUPS_ALLOWED=true
SHOW_PASSWORD_HINT=false
IP_HEADER=X-Forwarded-For
LOG_FILE=/opt/vaultwarden/data/vaultwarden.log
ADMIN_TOKEN='${ADMIN_HASH}'
EOF

chown vaultwarden:vaultwarden /opt/vaultwarden/.env
chmod 640 /opt/vaultwarden/.env
msg_ok "Configuration written"

# ------------------------------------------------------------------
# 8. systemd unit
# ------------------------------------------------------------------
msg_info "Creating systemd service"
cat >/etc/systemd/system/vaultwarden.service <<'UNIT'
[Unit]
Description=Vaultwarden Server (PostgreSQL)
After=network.target postgresql.service
Wants=postgresql.service

[Service]
User=vaultwarden
Group=vaultwarden
EnvironmentFile=/opt/vaultwarden/.env
WorkingDirectory=/opt/vaultwarden
ExecStart=/usr/bin/vaultwarden
Restart=always
RestartSec=5
AmbientCapabilities=CAP_NET_BIND_SERVICE
ReadWritePaths=/opt/vaultwarden
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
UNIT
msg_ok "systemd service created"

# ------------------------------------------------------------------
# 9. Запуск сервиса
# ------------------------------------------------------------------
msg_info "Starting Vaultwarden"
systemctl daemon-reload
$STD systemctl enable vaultwarden
$STD systemctl restart vaultwarden
sleep 5

if ! systemctl is-active --quiet vaultwarden; then
  msg_error "Vaultwarden не запустился — проверь: journalctl -u vaultwarden -n 50"
  exit 1
fi
msg_ok "Vaultwarden started"

# ------------------------------------------------------------------
# 10. Итог
# ------------------------------------------------------------------
msg_ok "Установка завершена!"
echo -e "${CREATING}${GN}Vaultwarden PG успешно установлен!${CL}"
echo -e "${INFO}${YW} Адрес (HTTP, без TLS):${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:8000${CL}"
echo -e "${INFO}${YW} Панель администратора:${CL}"
echo -e "${TAB}${BGN}http://${IP}:8000/admin${CL}"
echo -e "${INFO}${YW} Admin token (сохрани сейчас — больше не будет показан):${CL}"
echo -e "${TAB}${BGN}${ADMIN_RAW}${CL}"
echo -e "${INFO}${YW} Конфиг и пароль PostgreSQL:${CL}"
echo -e "${TAB}/opt/vaultwarden/.env${CL}"
echo -e "${INFO}${YW} Для HTTPS: добавь reverse proxy и смени DOMAIN= в .env${CL}"
