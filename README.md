# DecentMesh Relay — Seed Binaries

Pre-built relay binaries for bootstrapping the DecentMesh network.

## One-Liner Install

**Basic** (no hardening):

```bash
curl -sSL https://raw.githubusercontent.com/jiri-otoupal/DecentMeshSeedBinaries/refs/heads/master/setup-relay-no-hardening.sh | sudo bash
```

**Hardened** (recommended for production):

```bash
curl -sSL https://raw.githubusercontent.com/jiri-otoupal/DecentMeshSeedBinaries/refs/heads/master/setup-relay.sh | sudo bash
```

## Available Binaries

| File | Platform |
|---|---|
| `relay-linux-x86_64-<version>` | Linux x86_64 (Intel/AMD) |
| `relay-linux-aarch64-<version>` | Linux ARM64 (Raspberry Pi 4/5, AWS Graviton, Oracle Ampere) |

## Quick Start

```bash
# Download the binary for your platform
chmod +x relay-linux-*

# Run with default settings (port 8888)
./relay-linux-x86_64-0.1.23

# Or specify a custom port
./relay-linux-x86_64-0.1.23 --port 9999
```

## Automated Deployment

### Basic (no hardening)

Installs the relay with only the essentials (systemd service + UFW firewall) — **no** SSH/kernel hardening:

```bash
curl -sSL https://raw.githubusercontent.com/jiri-otoupal/DecentMeshSeedBinaries/refs/heads/master/setup-relay-no-hardening.sh | sudo bash
```

### Hardened (recommended for production)

Installs the relay **with** full system hardening (SSH lockdown, fail2ban, kernel hardening, audit, AIDE, AppArmor, etc.):

```bash
curl -sSL https://raw.githubusercontent.com/jiri-otoupal/DecentMeshSeedBinaries/refs/heads/master/setup-relay.sh | sudo bash
```

Both scripts configure systemd, firewall, and auto-restart. The hardened variant additionally applies SSH lockdown, kernel hardening, fail2ban, audit logging, and more.

## Building From Source

Run `build_release.bat` from the workspace root (requires [Zig](https://ziglang.org) + `cargo-zigbuild`):

```bash
cargo install cargo-zigbuild
build_release.bat
```

Binaries are output to `release/<version>/`.
