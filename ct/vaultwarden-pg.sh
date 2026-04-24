#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)

# Vaultwarden + PostgreSQL LXC
# Запускается на ХОСТЕ Proxmox.

APP="Vaultwarden-PG"
var_tags="${var_tags:-password-manager;postgresql}"
var_cpu="${var_cpu:-4}"
var_ram="${var_ram:-6144}"
var_disk="${var_disk:-20}"
var_os="${var_os:-debian}"
var_version="${var_version:-12}"
var_unprivileged="${var_unprivileged:-1}"

REPO_RAW="https://raw.githubusercontent.com/setwillis/Proxmox/main"

header_info "$APP"
variables
color
catch_errors

function update_script() {
  header_info
  check_container_storage
  check_container_resources

  if [[ ! -f /etc/systemd/system/vaultwarden.service ]]; then
    msg_error "No ${APP} installation found!"
    exit 1
  fi

  UPD=$(whiptail --title "Vaultwarden PG Update" --menu "Choose an action:" 15 60 3 \
    "1" "Update Vaultwarden + Web-Vault" \
    "2" "Set Admin Token" \
    "3" "Show Current Config" \
    3>&1 1>&2 2>&3) || exit 0

  case "$UPD" in
    1)
      msg_info "Stopping Vaultwarden"
      systemctl stop vaultwarden
      msg_ok "Stopped Vaultwarden"

      msg_info "Installing build dependencies"
      $STD apt-get update
      $STD apt-get install -y \
        build-essential clang pkg-config libssl-dev cmake git curl wget jq unzip \
        postgresql-server-dev-all ca-certificates argon2
      msg_ok "Build dependencies installed"

      ensure_profile_loaded
      if ! command -v cargo >/dev/null 2>&1; then
        msg_info "Installing Rust toolchain"
        curl https://sh.rustup.rs -sSf | sh -s -- -y >/dev/null 2>&1
        # shellcheck disable=SC1091
        source /root/.cargo/env
        msg_ok "Rust toolchain installed"
      fi
      # shellcheck disable=SC1091
      source /root/.cargo/env 2>/dev/null || true

      VW_RELEASE=$(curl -fsSL "https://api.github.com/repos/dani-garcia/vaultwarden/releases/latest" \
        | grep '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')
      WEB_RELEASE=$(curl -fsSL "https://api.github.com/repos/dani-garcia/bw_web_builds/releases/latest" \
        | grep '"tag_name"' | sed -E 's/.*"tag_name": *"([^"]+)".*/\1/')

      msg_info "Building Vaultwarden ${VW_RELEASE}"
      rm -rf /tmp/vaultwarden-src
      curl -fsSL "https://github.com/dani-garcia/vaultwarden/archive/refs/tags/${VW_RELEASE}.tar.gz" \
        | tar -xz -C /tmp --transform "s|^[^/]*|vaultwarden-src|"
      cd /tmp/vaultwarden-src || { msg_error "Source directory missing"; exit 1; }
      VW_VERSION="$VW_RELEASE" cargo build --features "postgresql" --release >/dev/null 2>&1
      install -m 0755 target/release/vaultwarden /usr/bin/vaultwarden
      cd ~
      rm -rf /tmp/vaultwarden-src
      msg_ok "Updated Vaultwarden to ${VW_RELEASE}"

      msg_info "Updating Web-Vault to ${WEB_RELEASE}"
      WEB_URL=$(curl -fsSL "https://api.github.com/repos/dani-garcia/bw_web_builds/releases/tags/${WEB_RELEASE}" \
        | grep '"browser_download_url"' | grep 'bw_web_.*\.tar\.gz' | head -n1 \
        | sed -E 's/.*"browser_download_url": *"([^"]+)".*/\1/')
      rm -rf /opt/vaultwarden/web-vault
      mkdir -p /opt/vaultwarden/web-vault
      curl -fsSL "$WEB_URL" | tar -xz -C /opt/vaultwarden/web-vault --strip-components=1
      chown -R vaultwarden:vaultwarden /opt/vaultwarden/web-vault
      msg_ok "Updated Web-Vault to ${WEB_RELEASE}"

      msg_info "Starting Vaultwarden"
      systemctl start vaultwarden
      msg_ok "Started Vaultwarden"
      ;;

    2)
      read -r -s -p "Enter new ADMIN_TOKEN: " NEWTOKEN
      echo ""
      if [[ -z "$NEWTOKEN" ]]; then
        msg_warn "Empty token — nothing changed"
        exit 0
      fi
      if ! command -v argon2 >/dev/null 2>&1; then
        $STD apt-get install -y argon2
      fi
      TOKEN=$(echo -n "${NEWTOKEN}" | argon2 "$(openssl rand -base64 32)" -t 2 -m 16 -p 4 -l 64 -e)
      sed -i "s|^ADMIN_TOKEN=.*|ADMIN_TOKEN='${TOKEN}'|" /opt/vaultwarden/.env
      systemctl restart vaultwarden
      msg_ok "Admin token updated and Vaultwarden restarted"
      ;;

    3)
      msg_info "Current /opt/vaultwarden/.env (sensitive values hidden)"
      grep -E '^(DOMAIN|DATABASE_URL|ROCKET_PORT|SIGNUPS_ALLOWED|ADMIN_TOKEN)=' \
        /opt/vaultwarden/.env \
        | sed 's/ADMIN_TOKEN=.*/ADMIN_TOKEN=<hidden>/' \
        | sed 's|DATABASE_URL=postgresql://[^:]*:[^@]*@|DATABASE_URL=postgresql://<user>:<hidden>@|'
      ;;
  esac
  exit 0
}

# start() показывает диалог "Default / Advanced Settings"
# В Advanced можно выбрать хранилище, сеть, CPU, RAM и т.д.
# build_container() создаёт LXC на основе выбранных настроек.
start
build_container
description

# Запускаем наш install-скрипт внутри созданного контейнера
msg_info "Running install script inside LXC ${CTID}"
pct exec "$CTID" -- bash -c \
  "curl -fsSL ${REPO_RAW}/install/vaultwarden-pg-install.sh | bash" \
  || { msg_error "Install script failed inside LXC ${CTID}"; exit 1; }
msg_ok "Install script completed"
