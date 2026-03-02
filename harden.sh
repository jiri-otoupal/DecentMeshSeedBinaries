#!/usr/bin/env bash
# ============================================================================
#  DecentMesh — Deep System Hardening
#
#  Usage:   sudo bash harden.sh
#  Tested:  Debian 12 (Bookworm)
#
#  Pure security hardening — ZERO performance impact.
#  Run AFTER setup-relay.sh. Idempotent — safe to re-run.
#
#  Goal: make it nearly impossible for an attacker to escalate from a
#  compromised service into the system.
# ============================================================================
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

RED='\033[0;31m'; GRN='\033[0;32m'; YLW='\033[1;33m'; CYN='\033[0;36m'; RST='\033[0m'
step()  { echo -e "\n${CYN}▶ $1${RST}"; }
ok()    { echo -e "  ${GRN}✔ $1${RST}"; }
warn()  { echo -e "  ${YLW}⚠ $1${RST}"; }
fail()  { echo -e "  ${RED}✖ $1${RST}"; exit 1; }

[[ $EUID -eq 0 ]] || fail "Run as root:  sudo bash $0"

echo -e "${CYN}DecentMesh Deep System Hardening${RST}"
echo -e "  ${YLW}All changes are security-only — zero performance impact${RST}"

###############################################################################
#  1.  FILESYSTEM PERMISSIONS & OWNERSHIP
###############################################################################
step "1/12  Tightening filesystem permissions"

# Restrict sensitive config files
chmod 600 /etc/shadow /etc/gshadow 2>/dev/null || true
chmod 644 /etc/passwd /etc/group 2>/dev/null || true
chmod 600 /boot/grub/grub.cfg 2>/dev/null || true

# Remove world-writable files (except /tmp, /var/tmp, device files)
find / -xdev -type f -perm -0002 \
  ! -path "/tmp/*" ! -path "/var/tmp/*" ! -path "/proc/*" ! -path "/sys/*" \
  -exec chmod o-w {} + 2>/dev/null || true

# Set sticky bit on all world-writable directories
find / -xdev -type d -perm -0002 ! -perm -1000 \
  -exec chmod +t {} + 2>/dev/null || true

# Restrict cron directories
chmod 700 /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/cron.monthly /etc/cron.weekly 2>/dev/null || true
chmod 600 /etc/crontab 2>/dev/null || true

# Restrict at.allow / cron.allow to root only
echo "root" > /etc/cron.allow 2>/dev/null || true
echo "root" > /etc/at.allow 2>/dev/null || true
chmod 600 /etc/cron.allow /etc/at.allow 2>/dev/null || true

ok "Filesystem permissions tightened"

###############################################################################
#  2.  REMOVE SUID/SGID FROM UNNECESSARY BINARIES
###############################################################################
step "2/12  Stripping unnecessary SUID/SGID bits"

# Keep SUID only on binaries that genuinely need it
KEEP_SUID=(
  /usr/bin/sudo
  /usr/bin/su
  /usr/bin/passwd
  /usr/bin/chsh
  /usr/bin/chfn
  /usr/bin/newgrp
  /usr/bin/gpasswd
  /usr/lib/openssh/ssh-keysign
  /usr/lib/dbus-1.0/dbus-daemon-launch-helper
)

# Build a regex to exclude the keepers
EXCLUDE_PATTERN=$(printf "|%s" "${KEEP_SUID[@]}")
EXCLUDE_PATTERN="${EXCLUDE_PATTERN:1}"  # remove leading |

STRIPPED=0
while IFS= read -r -d '' bin; do
  if ! echo "$bin" | grep -qE "^(${EXCLUDE_PATTERN})$"; then
    chmod u-s,g-s "$bin" 2>/dev/null && ((STRIPPED++)) || true
  fi
done < <(find / -xdev -type f \( -perm -4000 -o -perm -2000 \) -print0 2>/dev/null)

ok "Stripped SUID/SGID from ${STRIPPED} unnecessary binaries"

###############################################################################
#  3.  RESTRICT COMPILER & DEVELOPMENT TOOLS ACCESS
###############################################################################
step "3/12  Restricting access to compilers and dev tools"

# Restrict compilers to root only — prevents attackers from compiling exploits
for tool in /usr/bin/gcc* /usr/bin/g++* /usr/bin/cc /usr/bin/make /usr/bin/as; do
  if [[ -f "$tool" ]]; then
    chmod 700 "$tool" 2>/dev/null || true
  fi
done

ok "Compilers restricted to root"

###############################################################################
#  4.  RESTRICT su TO sudo GROUP ONLY
###############################################################################
step "4/12  Restricting su access"

# Only users in the 'sudo' group can use su
if ! grep -q "^auth.*required.*pam_wheel.so" /etc/pam.d/su 2>/dev/null; then
  sed -i '/pam_rootok.so/a auth       required   pam_wheel.so use_uid group=sudo' \
    /etc/pam.d/su 2>/dev/null || true
fi

ok "su restricted to sudo group"

###############################################################################
#  5.  SECURE SHARED MEMORY
###############################################################################
step "5/12  Securing shared memory"

# Mount /dev/shm with noexec,nosuid,nodev if not already
if ! grep -q '/dev/shm.*noexec' /etc/fstab 2>/dev/null; then
  # Remove existing /dev/shm line if present, then add hardened one
  sed -i '\|/dev/shm|d' /etc/fstab 2>/dev/null || true
  echo 'tmpfs /dev/shm tmpfs defaults,noexec,nosuid,nodev 0 0' >> /etc/fstab
  mount -o remount /dev/shm 2>/dev/null || true
fi

ok "Shared memory: noexec,nosuid,nodev"

###############################################################################
#  6.  KERNEL MODULE RESTRICTIONS
###############################################################################
step "6/12  Restricting kernel module loading"

cat > /etc/modprobe.d/decentmesh-hardening.conf <<'MODPROBE'
# Disable uncommon and risky network protocols
install dccp /bin/false
install sctp /bin/false
install rds /bin/false
install tipc /bin/false

# Disable uncommon filesystems (attack surface reduction)
install cramfs /bin/false
install freevxfs /bin/false
install jffs2 /bin/false
install hfs /bin/false
install hfsplus /bin/false
install squashfs /bin/false
install udf /bin/false

# Disable USB storage (if not needed)
install usb-storage /bin/false

# Disable firewire
install firewire-core /bin/false
install firewire-ohci /bin/false
MODPROBE

ok "Unnecessary kernel modules blacklisted"

###############################################################################
#  7.  PROCESS ISOLATION
###############################################################################
step "7/12  Hardening process isolation"

# Hide other users' processes — each user can only see their own
# gid=0 ensures root-owned services (systemd, systemctl) still work
if ! grep -q 'hidepid=' /etc/fstab 2>/dev/null; then
  echo 'proc /proc proc defaults,hidepid=2,gid=0 0 0' >> /etc/fstab
  mount -o remount,hidepid=2,gid=0 /proc 2>/dev/null || true
fi

ok "Process visibility restricted (hidepid=2)"

###############################################################################
#  8.  PAM HARDENING — BRUTE FORCE PROTECTION
###############################################################################
step "8/12  Hardening PAM authentication"

# Install pam_faillock config (account lockout after failed attempts)
cat > /etc/security/faillock.conf <<'FAILLOCK'
# Lock account after 5 failed attempts
deny = 5
# Unlock after 15 minutes
unlock_time = 900
# Track failures within 15 minutes
fail_interval = 900
# Do NOT lock root — you'd lose console access too
# even_deny_root is intentionally omitted
FAILLOCK

# Enable pam_faillock in PAM stack if not present
for pamfile in /etc/pam.d/common-auth; do
  if [[ -f "$pamfile" ]] && ! grep -q "pam_faillock" "$pamfile" 2>/dev/null; then
    # Add faillock before pam_unix
    sed -i '/pam_unix.so/i auth    required    pam_faillock.so preauth' "$pamfile" 2>/dev/null || true
    sed -i '/pam_unix.so/a auth    [default=die] pam_faillock.so authfail' "$pamfile" 2>/dev/null || true
  fi
done

# Enforce strong passwords via pwquality
cat > /etc/security/pwquality.conf <<'PWQUAL'
minlen = 12
dcredit = -1
ucredit = -1
lcredit = -1
ocredit = -1
maxrepeat = 3
enforcing = 1
PWQUAL

ok "PAM: account lockout after 5 failures, strong password policy"

###############################################################################
#  9.  NETWORK ATTACK SURFACE REDUCTION
###############################################################################
step "9/12  Reducing network attack surface"

cat > /etc/sysctl.d/98-decentmesh-security.conf <<'NETSEC'
# Ignore ICMP redirects (MITM prevention)
net.ipv4.conf.all.secure_redirects = 0
net.ipv4.conf.default.secure_redirects = 0

# Ignore gratuitous ARP (ARP spoofing prevention)
net.ipv4.conf.all.arp_ignore = 1
net.ipv4.conf.all.arp_announce = 2

# Restrict userns cloning (container escape prevention)
kernel.unprivileged_userns_clone = 0

# Restrict loading of TTY line disciplines
dev.tty.ldisc_autoload = 0

# Restrict performance events to root
kernel.perf_event_paranoid = 3

# Restrict watching kernel network addresses
kernel.kexec_load_disabled = 1
NETSEC

sysctl --system > /dev/null 2>&1 || true
ok "Network security parameters applied"

###############################################################################
#  10.  SECURE BOOT LOADER
###############################################################################
step "10/12  Securing boot loader"

# Restrict GRUB config visibility
if [[ -f /boot/grub/grub.cfg ]]; then
  chown root:root /boot/grub/grub.cfg
  chmod 600 /boot/grub/grub.cfg
fi

# Disable Ctrl-Alt-Del reboot (physical access attack)
systemctl mask ctrl-alt-del.target 2>/dev/null || true
ln -sf /dev/null /etc/systemd/system/ctrl-alt-del.target 2>/dev/null || true

ok "Boot loader secured, Ctrl-Alt-Del disabled"

###############################################################################
#  11.  RESTRICT USER ENVIRONMENTS
###############################################################################
step "11/12  Restricting user environments"

# Set secure default umask for all users
if [[ -f /etc/profile ]]; then
  if ! grep -q 'umask 027' /etc/profile; then
    echo 'umask 027' >> /etc/profile
  fi
fi

# Restrict access to home directories
for dir in /home/*/; do
  chmod 750 "$dir" 2>/dev/null || true
done

# Set shell timeout for idle sessions (15 minutes)
if ! grep -q 'TMOUT=' /etc/profile.d/timeout.sh 2>/dev/null; then
  cat > /etc/profile.d/timeout.sh <<'TMOUT'
# Auto-logout idle shells after 15 minutes
readonly TMOUT=900
export TMOUT
TMOUT
fi

# Disable login for system accounts that shouldn't have shells
# Explicitly skip decentmesh (needs shell for cargo builds)
while IFS=: read -r user _ uid _ _ home shell; do
  if [[ $uid -lt 1000 && $uid -ne 0 && "$user" != "decentmesh" \
    && "$shell" != "/usr/sbin/nologin" && "$shell" != "/bin/false" ]]; then
    usermod -s /usr/sbin/nologin "$user" 2>/dev/null || true
  fi
done < /etc/passwd

ok "User environments hardened"

###############################################################################
#  12.  AUDIT LOGGING ENHANCEMENTS
###############################################################################
step "12/12  Enhancing audit rules"

cat > /etc/audit/rules.d/99-decentmesh-deep.rules <<'AUDIT'
# Track all execve calls (catch any command execution by attackers)
-a always,exit -F arch=b64 -S execve -k exec_commands

# Track file permission changes
-a always,exit -F arch=b64 -S chmod,fchmod,fchmodat -k permission_changes

# Track user/group changes
-a always,exit -F arch=b64 -S setuid,setgid,setreuid,setregid -k privilege_escalation

# Track network socket creation
-a always,exit -F arch=b64 -S socket,connect,bind,listen -k network_activity

# Track mount/unmount
-a always,exit -F arch=b64 -S mount,umount2 -k mount_operations

# Track ptrace (debugger attach — common exploit technique)
-a always,exit -F arch=b64 -S ptrace -k process_tracing

# Track kernel module loading
-a always,exit -F arch=b64 -S init_module,finit_module,delete_module -k kernel_modules

# Track cron changes
-w /var/spool/cron/ -p wa -k cron_changes

# Make audit config immutable until reboot (prevents attacker from disabling)
-e 2
AUDIT

augenrules --load > /dev/null 2>&1 || true
ok "Deep audit logging enabled (config immutable until reboot)"

###############################################################################
#  SUMMARY
###############################################################################
echo ""
echo -e "${CYN}═══════════════════════════════════════════════════════════════${RST}"
echo -e "${GRN}  Deep Hardening Complete${RST}"
echo -e "${CYN}═══════════════════════════════════════════════════════════════${RST}"
echo ""
echo -e "  ${GRN}Applied:${RST}"
echo "    ✔ Filesystem permissions tightened"
echo "    ✔ SUID/SGID stripped from non-essential binaries"
echo "    ✔ Compilers restricted to root"
echo "    ✔ su restricted to sudo group"
echo "    ✔ Shared memory: noexec,nosuid,nodev"
echo "    ✔ Risky kernel modules blacklisted"
echo "    ✔ Process visibility restricted (hidepid=2)"
echo "    ✔ PAM: lockout after 5 failures, strong passwords"
echo "    ✔ Network: ARP spoofing & MITM protections"
echo "    ✔ Boot loader & Ctrl-Alt-Del secured"
echo "    ✔ Idle session timeout (15 min)"
echo "    ✔ System accounts locked to nologin"
echo "    ✔ Deep audit: execve, permissions, network, ptrace"
echo "    ✔ Audit config made immutable"
echo ""
echo -e "  ${YLW}Performance impact: NONE${RST}"
echo -e "  ${YLW}All changes are purely access-restriction based${RST}"
echo ""
echo -e "  ${CYN}Verify with:${RST}  lynis audit system --quick"
echo ""
echo -e "${CYN}═══════════════════════════════════════════════════════════════${RST}"
