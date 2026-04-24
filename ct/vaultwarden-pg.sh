#!/usr/bin/env bash
source <(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/build.func)

# Vaultwarden + PostgreSQL LXC
# Runs on the Proxmox HOST — creates and configures the container,
# then triggers the install script inside the LXC.

APP="Vaultwarden PG"
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

  # ------------------------------------------------------------------
  # Menu: update options
  # ------------------------------------------------------------------
  UPD=$(whiptail --title "Vaultwarden PG Update" --menu "Choose an action:" 15 60 3 \
    "1" "Update Vaultwarden + Web-Vault" \
    "2" "Set Admin Token" \
    "3" "Show Current Config" \
    3>&1 1>&2 2>&3) || exit 0

  case "$UPD" in
    1)
      VW_RELEASE=$(get_latest_github_release "dani-garcia/vaultwarden")
      WEB_RELEASE=$(get_latest_github_release "dani-garcia/bw_web_builds")

      msg_info "Stopping Vaultwarden"
      systemctl stop vaultwarden
      msg_ok "Stopped Vaultwarden"

      msg_info "Installing build dependencies"
      $STD apt-get update
      $STD apt-get install -y \
        build-essential clang pkg-config libssl-dev cmake git curl wget jq unzip \
        postgresql-server-dev-all ca-certificates argon2
      msg_ok "Build dependencies installed"

      # Ensure Rust is available (may have been installed at first install)
      ensure_profile_loaded
      if ! command -v cargo >/dev/null 2>&1; then
        msg_info "Installing Rust toolchain"
        curl https://sh.rustup.rs -sSf | sh -s -- -y >/dev/null 2>&1
        source /root/.cargo/env
        msg_ok "Rust toolchain installed"
      fi
      source /root/.cargo/env 2>/dev/null || true

      msg_info "Building Vaultwarden ${VW_RELEASE}"
      rm -rf /tmp/vaultwarden-src
      fetch_and_deploy_gh_release "vaultwarden" "dani-garcia/vaultwarden" "tarball" "${VW_RELEASE}" "/tmp/vaultwarden-src"
      cd /tmp/vaultwarden-src || { msg_error "Source directory missing"; exit 1; }
      VW_VERSION="$VW_RELEASE" cargo build --features "postgresql" --release >/dev/null 2>&1
      install -m 0755 target/release/vaultwarden /usr/bin/vaultwarden
      cd ~
      rm -rf /tmp/vaultwarden-src
      msg_ok "Updated Vaultwarden to ${VW_RELEASE}"

      msg_info "Updating Web-Vault to ${WEB_RELEASE}"
      rm -rf /opt/vaultwarden/web-vault
      mkdir -p /opt/vaultwarden/web-vault
      fetch_and_deploy_gh_release "vaultwarden_webvault" "dani-garcia/bw_web_builds" "prebuild" "${WEB_RELEASE}" "/opt/vaultwarden/web-vault" "bw_web_*.tar.gz"
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
        | sed 's/DATABASE_URL=postgresql:\/\/[^:]*:[^@]*@/DATABASE_URL=postgresql:\/\/<user>:<hidden>@/'
      ;;
  esac
  exit 0
}

start
build_container
description

# Скачиваем и запускаем install-скрипт из своего репо внутри контейнера
msg_info "Running install script inside LXC"
pct exec "$CTID" -- bash -c \
  "curl -fsSL ${REPO_RAW}/install/vaultwarden-pg-install.sh | bash" \
  || { msg_error "Install script failed inside LXC ${CTID}"; exit 1; }
msg_ok "Install script completed"
