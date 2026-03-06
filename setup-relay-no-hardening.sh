#!/usr/bin/env bash
# ============================================================================
#  DecentMesh Relay — Basic Debian Server Setup (NO HARDENING)
#
#  Usage:   sudo bash setup-relay-no-hardening.sh
#  Tested:  Debian 12 (Bookworm)
#
#  This script installs and starts the relay without applying any system
#  hardening.  For a production-hardened deployment, use setup-relay.sh instead.
#
#  This script is idempotent — safe to re-run.
# ============================================================================
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

# ─── colours ────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; CYN='\033[0;36m'; RST='\033[0m'
step()  { echo -e "\n${CYN}▶ $1${RST}"; }
ok()    { echo -e "  ${GRN}✔ $1${RST}"; }
warn()  { echo -e "  ${YLW}⚠ $1${RST}"; }
fail()  { echo -e "  ${RED}✖ $1${RST}"; exit 1; }

# ─── must be root ───────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || fail "Run this script as root:  sudo bash $0"

# ─── configurable defaults ──────────────────────────────────────────────────
RELAY_USER="decentmesh"
RELAY_HOME="/home/${RELAY_USER}"
INSTALL_DIR="/opt/decentmesh"
SERVICE_NAME="decentmesh-relay"
RELAY_PORT=8888
SSH_PORT=22
BINARY_REPO="https://raw.githubusercontent.com/jiri-otoupal/DecentMeshSeedBinaries/refs/heads/master"

###############################################################################
#  1.  SYSTEM UPDATE & DEPENDENCIES
###############################################################################
step "1/5  Updating system packages"
apt-get update
apt-get upgrade -y
ok "System packages updated"

step "1/5  Installing minimal dependencies"
apt-get install -y \
  curl wget unzip \
  ufw \
  sudo ca-certificates gnupg lsb-release
ok "All dependencies installed"

###############################################################################
#  2.  CREATE decentmesh USER
###############################################################################
step "2/5  Creating '${RELAY_USER}' user"
if id "${RELAY_USER}" &>/dev/null; then
  ok "User '${RELAY_USER}' already exists — skipping"
else
  useradd --system --create-home --shell /bin/bash "${RELAY_USER}"
  ok "User '${RELAY_USER}' created"
fi
mkdir -p "${RELAY_HOME}"
chown "${RELAY_USER}:${RELAY_USER}" "${RELAY_HOME}"
chmod 750 "${RELAY_HOME}"

###############################################################################
#  3.  DOWNLOAD PRE-BUILT BINARY
###############################################################################
step "3/5  Downloading pre-built relay binary"

# Detect architecture
ARCH=$(uname -m)
case "${ARCH}" in
  x86_64)       BINARY_NAME="relay-linux-x86_64" ;;
  aarch64|arm64) BINARY_NAME="relay-linux-aarch64" ;;
  *) fail "Unsupported architecture: ${ARCH}. Only x86_64 and aarch64 are supported." ;;
esac

ZIP_NAME="${BINARY_NAME}.zip"
DOWNLOAD_URL="${BINARY_REPO}/${ZIP_NAME}"

mkdir -p "${INSTALL_DIR}"
cd "${INSTALL_DIR}"

step "3/5  Downloading ${ZIP_NAME} from DecentMeshSeedBinaries"
curl -fSL -o "${ZIP_NAME}" "${DOWNLOAD_URL}" \
  || fail "Failed to download ${DOWNLOAD_URL}"

unzip -o "${ZIP_NAME}" -d "${INSTALL_DIR}" > /dev/null
rm -f "${ZIP_NAME}"

# Find and set up the relay binary
RELAY_BIN_NAME=$(find "${INSTALL_DIR}" -maxdepth 1 -name 'relay*' -type f | head -1)
if [[ -z "${RELAY_BIN_NAME}" ]]; then
  fail "No relay binary found after unzip"
fi
mv "${RELAY_BIN_NAME}" "${INSTALL_DIR}/relay" 2>/dev/null || true
chmod +x "${INSTALL_DIR}/relay"
chown "${RELAY_USER}:${RELAY_USER}" "${INSTALL_DIR}/relay"

ok "Relay binary installed at ${INSTALL_DIR}/relay"

# Download config files from main repo (skip if already present)
CONFIG_REPO="https://raw.githubusercontent.com/jiri-otoupal/DecentMeshSeedBinaries/refs/heads/master"

if [[ ! -f "${INSTALL_DIR}/config.toml" ]]; then
  curl -fSL -o "${INSTALL_DIR}/config.toml" "${CONFIG_REPO}/config.toml" \
    || fail "Failed to download config.toml"
  chown "${RELAY_USER}:${RELAY_USER}" "${INSTALL_DIR}/config.toml"
  ok "Downloaded config.toml"
else
  ok "config.toml already exists — skipping"
fi

if [[ ! -f "${INSTALL_DIR}/seed_relays.toml" ]]; then
  curl -fSL -o "${INSTALL_DIR}/seed_relays.toml" "${CONFIG_REPO}/seed_relays.toml" \
    || fail "Failed to download seed_relays.toml"
  chown "${RELAY_USER}:${RELAY_USER}" "${INSTALL_DIR}/seed_relays.toml"
  ok "Downloaded seed_relays.toml"
else
  ok "seed_relays.toml already exists — skipping"
fi

###############################################################################
#  4.  SYSTEMD SERVICE
###############################################################################
step "4/5  Installing systemd service"
RELAY_BIN="${INSTALL_DIR}/relay"

# Ensure relay user owns the install dir and db directories exist
chown -R "${RELAY_USER}:${RELAY_USER}" "${INSTALL_DIR}"
mkdir -p "${INSTALL_DIR}/relay_db" "${INSTALL_DIR}/relay_db_${RELAY_PORT}"
chown -R "${RELAY_USER}:${RELAY_USER}" "${INSTALL_DIR}/relay_db" "${INSTALL_DIR}/relay_db_${RELAY_PORT}"

cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=DecentMesh Relay
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${RELAY_USER}
WorkingDirectory=${INSTALL_DIR}

Environment=RUST_LOG=info
Environment=RUST_BACKTRACE=1

ExecStart=${RELAY_BIN} --port ${RELAY_PORT} --config ${INSTALL_DIR}/config.toml --seeds ${INSTALL_DIR}/seed_relays.toml

Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

# Remove legacy updater if present
systemctl disable --now ${SERVICE_NAME}-updater.timer 2>/dev/null || true
rm -f /etc/systemd/system/${SERVICE_NAME}-updater.service
rm -f /etc/systemd/system/${SERVICE_NAME}-updater.timer
rm -f "${INSTALL_DIR}/check-update.sh"

systemctl daemon-reload
systemctl enable --now ${SERVICE_NAME}
ok "Service '${SERVICE_NAME}' enabled and started"

###############################################################################
#  5.  FIREWALL (UFW)
###############################################################################
step "5/5  Configuring firewall (UFW)"
ufw --force reset > /dev/null 2>&1
ufw default deny incoming
ufw default allow outgoing

# SSH
ufw allow ${SSH_PORT}/tcp comment "SSH"

# DecentMesh relay — QUIC is UDP only
ufw allow ${RELAY_PORT}/udp comment "DecentMesh Relay QUIC/UDP"

# Enable (--force skips the interactive prompt)
ufw --force enable
ok "UFW enabled — ports ${SSH_PORT}/tcp, ${RELAY_PORT}/udp open"

###############################################################################
#  DONE
###############################################################################
echo ""
echo -e "${CYN}═══════════════════════════════════════════════════════════════${RST}"
echo -e "${GRN}  DecentMesh Relay Setup Complete (no hardening)${RST}"
echo -e "${CYN}═══════════════════════════════════════════════════════════════${RST}"
echo ""
echo -e "  ${GRN}▸ Service:${RST}   ${SERVICE_NAME}"
echo -e "  ${GRN}▸ User:${RST}      ${RELAY_USER}"
echo -e "  ${GRN}▸ Binary:${RST}    ${RELAY_BIN}"
echo -e "  ${GRN}▸ Port:${RST}      ${RELAY_PORT} (UDP/QUIC)"
echo -e "  ${GRN}▸ Install:${RST}   ${INSTALL_DIR}"
echo ""
echo -e "  ${YLW}Useful commands:${RST}"
echo "    systemctl status ${SERVICE_NAME}"
echo "    journalctl -u ${SERVICE_NAME} -f"
echo "    ufw status numbered"
echo ""

# Firewall summary
echo -e "  ${CYN}Firewall rules:${RST}"
ufw status | grep -E "ALLOW|DENY" | sed 's/^/    /'
echo ""

# Service status
if systemctl is-active --quiet "${SERVICE_NAME}"; then
  echo -e "  ${GRN}✔ Relay service is RUNNING${RST}"
else
  echo -e "  ${RED}✖ Relay service is NOT running — check: journalctl -u ${SERVICE_NAME}${RST}"
fi
echo ""

echo -e "${GRN}═══════════════════════════════════════════════════════════════${RST}"
echo -e "${YLW}  ℹ  This setup does NOT include system hardening.${RST}"
echo -e "${YLW}     For production use, consider running setup-relay.sh instead.${RST}"
echo -e "${GRN}═══════════════════════════════════════════════════════════════${RST}"
