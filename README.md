# DecentMesh Relay — Seed Binaries

Pre-built relay binaries for bootstrapping the DecentMesh network.

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

## Hardened Deployment

For production relays, use the setup script from the main repo:

```bash
curl -sSL https://raw.githubusercontent.com/jiri-otoupal/DecentMesh-Relay/main/setup-relay.sh | bash
```

This configures systemd, firewall, QUIC tuning, and auto-restart.

## Building From Source

Run `build_release.bat` from the workspace root (requires [Zig](https://ziglang.org) + `cargo-zigbuild`):

```bash
cargo install cargo-zigbuild
build_release.bat
```

Binaries are output to `release/<version>/`.
