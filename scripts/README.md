# CKB Node Stability Script

A single script that hardens, fixes, and enhances any manually-installed CKB full node. Run it once, and your node gets everything it should have shipped with.

## Quick Start

```bash
curl -fsSL https://raw.githubusercontent.com/toastmanAu/armbian-ckb-userpatches/master/scripts/fix-ckb-stability.sh | sudo bash
```

---

## What It Installs

### 1 — Service Hardening
The default CKB service file has two critical bugs:
- `WatchdogSec=300` combined with `Type=simple` kills the node every 5 minutes — CKB doesn't implement `sd_notify`, so systemd thinks it's hung even when it's syncing fine
- `StartLimitBurst=5` means systemd gives up restarting after 5 failures in 5 minutes — a node can go permanently offline without anyone noticing

The script applies a drop-in override (non-destructive — original file untouched):
- `WatchdogSec=0` — disables the faulty watchdog
- `Restart=always` — restarts on any exit, not just failures
- `StartLimitIntervalSec=0` — never stops retrying
- `LimitNOFILE=65536` — enough file descriptors for 50+ peers + indexer
- `TimeoutStopSec=60` — gives CKB time to flush its database before force-kill

### 2 — WiFi Power-Save Disabled
On WiFi-connected nodes, Linux puts the NIC to sleep between packets. This causes peer connections to drop silently and sync to stall. Fixed with a udev rule that disables power management on all `wlan*` interfaces, applied immediately and persistently on boot.

### 3 — Auto-Start on Boot
`systemctl enable ckb` — ensures the node comes back up after a reboot. Surprisingly often not set on manual installs.

### 4 — Application-Level Watchdog
A systemd timer runs every 5 minutes and:
- Polls the CKB RPC for the current tip block number
- If the block height hasn't advanced in **10 minutes** → restarts `ckb.service`
- If the RPC is unreachable for **10 minutes** → restarts `ckb.service`

This catches stuck syncs that the service-level watchdog can't detect (node is running but not progressing).

```bash
journalctl -u ckb-watchdog -f   # watch the watchdog
```

### 5 — Log Rotation
`ckb.log` grows without bound on default installs. Configures logrotate for daily rotation, 7-day retention, compressed archives.

### 6 — Auto-Update Checker
A daily systemd timer checks the CKB GitHub releases API for new versions.

**When a new version is found:**
- If run from a terminal: shows an interactive coloured prompt with the version number and release notes URL, with upgrade/cancel options
- If running headless (timer): sends a `wall` broadcast to all logged-in users, logs the event

**To trigger manually:**
```bash
sudo ckb-update-check
```

**Example prompt:**
```
╔══════════════════════════════════════════╗
║  CKB Update Available                    ║
╚══════════════════════════════════════════╝

  Current:  v0.202.0
  Latest:   v0.204.0

  Release notes: https://github.com/nervosnetwork/ckb/releases/tag/v0.204.0

  Upgrade now? [Y/n]
```

Selecting Y: downloads the correct binary for your architecture (x86_64 or arm64), stops the service, installs it, restarts, and confirms the new version.

### 7 — CKB Dashboard + `ckbnode.local`
Installs [ckb-node-dashboard](https://github.com/toastmanAu/ckb-node-dashboard) — a live web dashboard showing block height, sync status, peers, and more.

- Runs as a systemd service on port 8080
- Sets the machine hostname to `ckbnode`
- Installs avahi (mDNS) so `http://ckbnode.local` resolves on your LAN from any device — no IP addresses needed

After upgrade, the dashboard shows the updated version and live chain stats.

### 8 — Working Directory Migration
Nodes installed to `/home/orangepi/ckb/` are migrated to `/opt/ckb/` — a more appropriate location for a system service. The old path is preserved as a symlink for compatibility with any existing scripts.

---

## Idempotent

Safe to run multiple times. Each step checks whether it's already done and skips with a clear `–` indicator. Only applies what's missing.

---

## What It Does Not Touch

- Your `ckb.toml` config — untouched
- Your chain data — untouched (migrated with `rsync -a`, original backed up)
- Mainnet vs testnet — detected from your existing config
- The original `ckb.service` file — all changes are drop-in overrides

---

## Files Installed

| Path | Purpose |
|------|---------|
| `/etc/systemd/system/ckb.service.d/hardened.conf` | Service drop-in |
| `/etc/udev/rules.d/70-wifi-powersave.rules` | WiFi power-save |
| `/etc/logrotate.d/ckb` | Log rotation |
| `/usr/local/bin/ckb-watchdog` | Watchdog script |
| `/etc/systemd/system/ckb-watchdog.{service,timer}` | Watchdog timer |
| `/usr/local/bin/ckb-update-check` | Update checker script |
| `/etc/systemd/system/ckb-update-check.{service,timer}` | Daily update timer |
| `/opt/ckb-dashboard/` | Dashboard app |
| `/etc/systemd/system/ckb-dashboard.service` | Dashboard service |
| `/etc/avahi/services/ckbnode.service` | mDNS advertisement |

---

## Requirements

- Debian/Ubuntu-based system (apt)
- `ckb.service` already installed
- Root / sudo access
- Internet access (for dashboard clone + update checks)

Tested on: Orange Pi 3B, Orange Pi 5, Raspberry Pi 4/5, x86_64 Ubuntu
