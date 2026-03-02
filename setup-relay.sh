#!/usr/bin/env bash
# ============================================================================
#  DecentMesh Relay — Full Debian Server Setup
#
#  Usage:   sudo bash setup-relay.sh
#  Tested:  Debian 12 (Bookworm)
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
step "1/7  Updating system packages"
apt-get update
apt-get upgrade -y
ok "System packages updated"

step "1/7  Installing security tools & dependencies"
apt-get install -y \
  curl wget unzip \
  ufw fail2ban unattended-upgrades apt-listchanges \
  auditd audispd-plugins \
  lynis \
  acl apparmor apparmor-utils \
  libpam-pwquality \
  sudo ca-certificates gnupg lsb-release
ok "All dependencies installed"

###############################################################################
#  2.  CREATE decentmesh USER
###############################################################################
step "2/7  Creating '${RELAY_USER}' user"
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
step "3/7  Downloading pre-built relay binary"

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

step "3/7  Downloading ${ZIP_NAME} from DecentMeshSeedBinaries"
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
CONFIG_REPO="https://raw.githubusercontent.com/jiri-otoupal/DecentMesh-Relay/refs/heads/master"

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
step "4/7  Installing systemd service"
RELAY_BIN="${INSTALL_DIR}/relay"

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

ExecStart=${RELAY_BIN} --port ${RELAY_PORT}

Restart=always
RestartSec=3
LimitNOFILE=1048576

# Hardening (safe on all systems)
NoNewPrivileges=true
RestrictSUIDSGID=true
EOF

# Add namespace-based hardening ONLY if the system actually supports it.
# The old `unshare --mount true` check passes as root even in containers
# where systemd's ProtectSystem/PrivateTmp fail for service users.
CAN_NAMESPACE=false

# Quick disqualifiers: known container environments
if [[ -f /.dockerenv ]] \
   || grep -qi 'lxc\|openvz\|docker\|container' /proc/1/environ 2>/dev/null \
   || [[ "$(systemd-detect-virt 2>/dev/null)" =~ ^(lxc|openvz|docker|podman)$ ]]; then
  CAN_NAMESPACE=false
# Positive test: ask systemd to actually apply ProtectSystem for the relay user
elif systemd-run --quiet --user -M "${RELAY_USER}@" --wait \
     -p ProtectSystem=strict -p PrivateTmp=true \
     /bin/true 2>/dev/null; then
  CAN_NAMESPACE=true
# Fallback: try unshare as the relay user (not root)
elif sudo -u "${RELAY_USER}" unshare --mount true 2>/dev/null; then
  CAN_NAMESPACE=true
fi

if $CAN_NAMESPACE; then
  cat >> /etc/systemd/system/${SERVICE_NAME}.service <<NSEOF

# Namespace hardening (verified working on this system)
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=${INSTALL_DIR}/relay_db ${INSTALL_DIR}/relay_db_${RELAY_PORT}
PrivateTmp=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
MemoryDenyWriteExecute=true
NSEOF
  ok "Full namespace hardening enabled"
else
  warn "No namespace support (container?) — using basic hardening only"
fi

# Append [Install] section
cat >> /etc/systemd/system/${SERVICE_NAME}.service <<'INSTEOF'

[Install]
WantedBy=multi-user.target
INSTEOF

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
step "5/7  Configuring firewall (UFW)"
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
#  6.  SYSTEM HARDENING
###############################################################################
step "6/7  Applying system hardening"

# ── 6a. SSH hardening (pubkey-only, no password auth) ───────────────────────
SSHD_CONF="/etc/ssh/sshd_config.d/99-decentmesh-hardening.conf"
cat > "${SSHD_CONF}" <<'SSHEOF'
# DecentMesh SSH Hardening — pubkey only
PermitRootLogin prohibit-password
MaxAuthTries 3
MaxSessions 3
LoginGraceTime 30
ClientAliveInterval 300
ClientAliveCountMax 2

X11Forwarding no
AllowTcpForwarding no
AllowAgentForwarding no
PermitTunnel no

# Auth: pubkey only — no passwords, no keyboard-interactive
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
UsePAM yes
AuthenticationMethods publickey

# Strong crypto
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com

# Banner
Banner /etc/issue.net
SSHEOF

# Validate config before restarting — never break a running sshd
if sshd -t -f /etc/ssh/sshd_config 2>/dev/null; then
  systemctl restart sshd
  ok "SSH hardened (pubkey-only, password auth disabled)"
else
  warn "sshd config validation failed — rolling back"
  rm -f "${SSHD_CONF}"
  fail "SSH config was invalid. Removed drop-in to keep SSH working. Fix manually."
fi

# ── 6b. Legal banner ───────────────────────────────────────────────────────
cat > /etc/issue.net <<'BANNER'
***************************************************************************
*  UNAUTHORIZED ACCESS TO THIS SYSTEM IS PROHIBITED.                     *
*  All connections are logged and monitored. By accessing this system,    *
*  you consent to monitoring. Disconnect immediately if you are not an    *
*  authorized user.                                                      *
***************************************************************************
BANNER
ok "Legal banner set"

# ── 6c. Kernel hardening ───────────────────────────────────────────────────
cat > /etc/sysctl.d/99-decentmesh-hardening.conf <<'SYSCTL'
# ── Network ──
net.ipv4.ip_forward = 0
net.ipv6.conf.all.forwarding = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.default.accept_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.default.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1
net.ipv4.tcp_syncookies = 1
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_ignore_bogus_error_responses = 1

# ── Kernel ──
kernel.randomize_va_space = 2
kernel.dmesg_restrict = 1
kernel.kptr_restrict = 2
kernel.yama.ptrace_scope = 2
kernel.unprivileged_bpf_disabled = 1
net.core.bpf_jit_harden = 2
kernel.sysrq = 0

# ── Performance tuning for relay ──
net.core.rmem_max = 26214400
net.core.wmem_max = 26214400
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.udp_rmem_min = 8192
net.ipv4.udp_wmem_min = 8192
net.core.netdev_max_backlog = 50000
SYSCTL

sysctl --system > /dev/null 2>&1
ok "Kernel parameters hardened + relay network tuning applied"

# ── 6d. fail2ban ───────────────────────────────────────────────────────────
cat > /etc/fail2ban/jail.d/decentmesh.conf <<'F2B'
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 3
backend  = systemd

[sshd]
enabled  = true
port     = ssh
filter   = sshd
maxretry = 3
bantime  = 7200
F2B

systemctl enable --now fail2ban
systemctl restart fail2ban
ok "fail2ban configured and started"

# ── 6e. Automatic security updates ────────────────────────────────────────
cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'APT'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
APT

cat > /etc/apt/apt.conf.d/20auto-upgrades <<'APT2'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::Download-Upgradeable-Packages "1";
APT::Periodic::AutocleanInterval "7";
APT2

ok "Automatic security updates enabled"

# ── 6f. Audit daemon ──────────────────────────────────────────────────────
cat > /etc/audit/rules.d/decentmesh.rules <<'AUDIT'
# Monitor authentication
-w /etc/pam.d/ -p wa -k pam_changes
-w /etc/shadow -p wa -k shadow_changes
-w /etc/passwd -p wa -k passwd_changes
-w /etc/group -p wa -k group_changes
-w /etc/sudoers -p wa -k sudoers_changes
-w /etc/sudoers.d/ -p wa -k sudoers_d_changes

# Monitor SSH config
-w /etc/ssh/sshd_config -p wa -k sshd_config
-w /etc/ssh/sshd_config.d/ -p wa -k sshd_config_d

# Monitor systemd services
-w /etc/systemd/system/ -p wa -k systemd_changes

# Monitor login/logout
-w /var/log/auth.log -p wa -k auth_log
-w /var/log/faillog -p wa -k faillog
-w /var/log/lastlog -p wa -k lastlog

# Monitor kernel module loading
-w /sbin/insmod -p x -k kernel_modules
-w /sbin/rmmod -p x -k kernel_modules
-w /sbin/modprobe -p x -k kernel_modules
AUDIT

systemctl enable --now auditd
augenrules --load > /dev/null 2>&1 || true
ok "Audit daemon configured"

# ── 6g. AIDE (intrusion detection baseline) ───────────────────────────────
# Install aide if not present
apt-get install -y -qq aide > /dev/null 2>&1 || true

AIDE_CUSTOM="/etc/aide/decentmesh-aide.conf"
AIDE_DB="/var/lib/aide/aide.db"

if command -v aide &>/dev/null && [[ ! -f "${AIDE_DB}" ]]; then
  step "6/7  Initializing AIDE database (critical files only)"

  # Standalone config — bypasses the default aide.conf entirely
  cat > "${AIDE_CUSTOM}" <<'AIDECONF'
# Only these specific files — nothing else
/etc/passwd          p+i+u+g+sha256
/etc/shadow          p+i+u+g+sha256
/etc/group           p+i+u+g+sha256
/etc/gshadow         p+i+u+g+sha256
/etc/sudoers         p+i+u+g+sha256
/etc/ssh/sshd_config p+i+u+g+sha256
/etc/crontab         p+i+u+g+sha256
/etc/fstab           p+i+u+g+sha256
/etc/hosts           p+i+u+g+sha256
/etc/login.defs      p+i+u+g+sha256
/usr/bin/sudo        p+i+u+g+sha256
/usr/bin/su          p+i+u+g+sha256
/usr/bin/passwd      p+i+u+g+sha256
/usr/sbin/sshd       p+i+u+g+sha256
AIDECONF

  aide --init --config="${AIDE_CUSTOM}" \
    --before="database_out=file:${AIDE_DB}.new" || true
  if [[ -f "${AIDE_DB}.new" ]]; then
    mv "${AIDE_DB}.new" "${AIDE_DB}"
  fi
  ok "AIDE baseline created (14 critical files)"
else
  ok "AIDE database already exists (or aide not installed)"
fi

# ── 6h. Restrict core dumps ──────────────────────────────────────────────
cat > /etc/security/limits.d/99-no-core.conf <<'LIMITS'
*  hard  core  0
LIMITS

echo 'fs.suid_dumpable = 0' > /etc/sysctl.d/99-no-coredump.conf
sysctl -p /etc/sysctl.d/99-no-coredump.conf > /dev/null 2>&1
ok "Core dumps disabled"

# ── 6i. Login hardening ──────────────────────────────────────────────────
# Set secure umask
sed -i 's/^UMASK.*/UMASK\t\t027/' /etc/login.defs 2>/dev/null || true

# Password aging for non-system accounts
sed -i 's/^PASS_MAX_DAYS.*/PASS_MAX_DAYS\t90/' /etc/login.defs 2>/dev/null || true
sed -i 's/^PASS_MIN_DAYS.*/PASS_MIN_DAYS\t1/' /etc/login.defs 2>/dev/null || true
sed -i 's/^PASS_WARN_AGE.*/PASS_WARN_AGE\t14/' /etc/login.defs 2>/dev/null || true

ok "Login policies hardened"

# ── 6j. Disable unnecessary services ────────────────────────────────────
for svc in avahi-daemon cups bluetooth; do
  if systemctl is-enabled "${svc}" &>/dev/null; then
    systemctl disable --now "${svc}" 2>/dev/null || true
    ok "Disabled ${svc}"
  fi
done

# ── 6k. Restrict /tmp & shared memory ───────────────────────────────────
if ! grep -q '/run/shm' /etc/fstab; then
  echo 'tmpfs /run/shm tmpfs defaults,noexec,nosuid,nodev 0 0' >> /etc/fstab
  ok "Shared memory restricted"
fi

# ── 6l. AppArmor ────────────────────────────────────────────────────────
if command -v aa-enforce &>/dev/null; then
  systemctl enable --now apparmor 2>/dev/null || true
  ok "AppArmor enabled"
fi

###############################################################################
#  7.  FINAL VALIDATION
###############################################################################
step "7/7  Final validation"

echo ""
echo -e "${CYN}═══════════════════════════════════════════════════════════════${RST}"
echo -e "${GRN}  DecentMesh Relay Setup Complete${RST}"
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
echo "    fail2ban-client status sshd"
echo "    lynis audit system --quick"
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

# Run quick Lynis audit
if command -v lynis &>/dev/null; then
  step "Running Lynis quick audit..."
  lynis audit system --quick --no-colors 2>/dev/null | tail -20 || true
  echo ""
fi

echo -e "${GRN}═══════════════════════════════════════════════════════════════${RST}"
echo -e "${YLW}  ⚠  IMPORTANT: Test SSH access from another terminal BEFORE${RST}"
echo -e "${YLW}     disconnecting to verify you are not locked out!${RST}"
echo -e "${GRN}═══════════════════════════════════════════════════════════════${RST}"
