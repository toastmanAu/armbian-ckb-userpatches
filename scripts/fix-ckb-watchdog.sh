#!/bin/bash
# fix-ckb-watchdog.sh — Remove bad WatchdogSec from ckb.service on existing nodes
#
# Problem: CKB uses Type=simple and does not implement sd_notify. If WatchdogSec
# is set, systemd kills the node every N seconds thinking it's hung, even when
# it's syncing normally. This causes a restart loop (restart counter climbs fast).
#
# Run this on any node built before 2026-03-02, or any node set up manually.
#
# Usage:
#   sudo bash fix-ckb-watchdog.sh                       # fix local node
#   ssh user@host 'sudo bash -s' < fix-ckb-watchdog.sh  # fix remote node

set -e

SERVICE=/etc/systemd/system/ckb.service
OVERRIDE_DIR=/etc/systemd/system/ckb.service.d
OVERRIDE=$OVERRIDE_DIR/no-watchdog.conf

echo "=== CKB watchdog fix ==="

if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root (sudo bash fix-ckb-watchdog.sh)"
    exit 1
fi

if [ ! -f "$SERVICE" ]; then
    echo "ckb.service not found at $SERVICE — nothing to do"
    exit 0
fi

WATCHDOG_SET=0
grep -q "WatchdogSec" "$SERVICE" 2>/dev/null && WATCHDOG_SET=1 && echo "Found WatchdogSec in $SERVICE"

STARTLIMIT_SET=0
grep -q "StartLimitIntervalSec" "$SERVICE" 2>/dev/null && STARTLIMIT_SET=1

if [ "$WATCHDOG_SET" -eq 0 ] && [ "$STARTLIMIT_SET" -eq 1 ]; then
    echo "ckb.service looks fine — no WatchdogSec, StartLimitIntervalSec present"
    echo "Nothing to fix."
    exit 0
fi

echo "Applying drop-in override at $OVERRIDE ..."
mkdir -p "$OVERRIDE_DIR"
cat > "$OVERRIDE" << 'EOF'
[Unit]
StartLimitIntervalSec=0

[Service]
# CKB uses Type=simple and does not send sd_notify keepalive pings.
# WatchdogSec causes systemd to SIGABRT the process on a fixed interval
# even when CKB is healthy and syncing. Disable it entirely.
WatchdogSec=0
RestartSec=15
EOF

echo "Drop-in written. Reloading systemd..."
systemctl daemon-reload

if systemctl is-active ckb >/dev/null 2>&1; then
    echo "Restarting ckb.service..."
    systemctl restart ckb
    sleep 3
    STATUS=$(systemctl is-active ckb)
    echo "ckb.service is now: $STATUS"
    if [ "$STATUS" = "active" ]; then
        echo "Fix applied successfully"
    else
        echo "Service did not come up — check: journalctl -u ckb -n 20"
        exit 1
    fi
else
    echo "ckb.service not running — drop-in applied, takes effect on next start"
fi

echo ""
echo "Verify with: journalctl -u ckb -n 30 | grep -i 'watchdog\|SIGABRT\|restart'"
