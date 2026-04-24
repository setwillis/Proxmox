#!/usr/bin/env bash
# shellcheck shell=bash
# Vaultwarden + PostgreSQL — install script
# Executed INSIDE the LXC container by build.func after container creation.
# Do NOT run this directly on the Proxmox host.

source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/core.func)
color; formatting; icons; load_functions; catch_errors

PWGEN() { tr -dc 'A-Za-z0-9' </dev/urandom | head -c "${1:-32}"; }

# ------------------------------------------------------------------
# Resolve the container's own IP (used in .env and summary output)
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
# 3. Service user & directory layout
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

# Create role if it doesn't exist
sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='${PG_USER}'" \
  | grep -q 1 \
  || sudo -u postgres psql -c \
       "CREATE USER ${PG_USER} WITH ENCRYPTED PASSWORD '${PG_PASS}';" >/dev/null 2>&1

# Create database if it doesn't exist
sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='${PG_DB}'" \
  | grep -q 1 \
  || sudo -u postgres psql -c \
       "CREATE DATABASE ${PG_DB} OWNER ${PG_USER};" >/dev/null 2>&1

sudo -u postgres psql -c "ALTER DATABASE ${PG_DB} OWNER TO ${PG_USER};" >/dev/null 2>&1
sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE ${PG_DB} TO ${PG_USER};" >/dev/null 2>&1

# Allow password (TCP) authentication for the vaultwarden user.
# Vaultwarden connects via 127.0.0.1, which uses md5/scram — not peer auth.
# Without this line a default Debian pg_hba.conf may reject the connection.
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
WEB_RELEASE=$(get_latest_github_release "dani-garcia/bw_web_builds")
msg_info "Downloading Web-Vault ${WEB_RELEASE}"
fetch_and_deploy_gh_release \
  "vaultwarden_webvault" \
  "dani-garcia/bw_web_builds" \
  "prebuild" \
  "${WEB_RELEASE}" \
  "/opt/vaultwarden/web-vault" \
  "bw_web_*.tar.gz"
chown -R vaultwarden:vaultwarden /opt/vaultwarden/web-vault
msg_ok "Web-Vault ${WEB_RELEASE} downloaded"

# ------------------------------------------------------------------
# 6. Build Vaultwarden from source
# ------------------------------------------------------------------
VAULT_RELEASE=$(get_latest_github_release "dani-garcia/vaultwarden")
msg_info "Building Vaultwarden ${VAULT_RELEASE} (this takes a while)"
rm -rf /tmp/vaultwarden-src
fetch_and_deploy_gh_release \
  "vaultwarden" \
  "dani-garcia/vaultwarden" \
  "tarball" \
  "${VAULT_RELEASE}" \
  "/tmp/vaultwarden-src"

cd /tmp/vaultwarden-src || { msg_error "Source directory missing after fetch"; exit 1; }
VW_VERSION="$VAULT_RELEASE" cargo build --features "postgresql" --release >/dev/null 2>&1
install -m 0755 target/release/vaultwarden /usr/bin/vaultwarden
cd ~
rm -rf /tmp/vaultwarden-src
msg_ok "Vaultwarden ${VAULT_RELEASE} built and installed"

# ------------------------------------------------------------------
# 7. Configuration file
# NOTE: DOMAIN uses http:// because Vaultwarden itself is plain HTTP.
#       Put a reverse proxy (Nginx, Caddy) in front for TLS.
#       Change to https:// once you add a TLS terminator.
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
# 8. systemd service
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
# 9. Start service
# ------------------------------------------------------------------
msg_info "Starting Vaultwarden"
systemctl daemon-reload
$STD systemctl enable vaultwarden
$STD systemctl restart vaultwarden
sleep 3

if ! systemctl is-active --quiet vaultwarden; then
  msg_error "Vaultwarden failed to start — check: journalctl -u vaultwarden -n 50"
  exit 1
fi
msg_ok "Vaultwarden started"

# ------------------------------------------------------------------
# 10. Summary
# ------------------------------------------------------------------
msg_ok "Installation complete!"
echo -e "${CREATING}${GN}${APP:-Vaultwarden PG} setup finished successfully!${CL}"
echo -e "${INFO}${YW} Access URL (HTTP, no TLS):${CL}"
echo -e "${TAB}${GATEWAY}${BGN}http://${IP}:8000${CL}"
echo -e "${INFO}${YW} Admin panel:${CL}"
echo -e "${TAB}${BGN}http://${IP}:8000/admin${CL}"
echo -e "${INFO}${YW} Admin token (SAVE THIS — shown only once):${CL}"
echo -e "${TAB}${BGN}${ADMIN_RAW}${CL}"
echo -e "${INFO}${YW} PostgreSQL credentials are in:${CL}"
echo -e "${TAB}/opt/vaultwarden/.env${CL}"
echo -e "${INFO}${YW} To enable HTTPS, add a reverse proxy and update DOMAIN= in .env${CL}"
