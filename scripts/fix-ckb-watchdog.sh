#!/bin/bash
# fix-ckb-watchdog.sh — Harden ckb.service on existing/manually-installed nodes
#
# What this does:
#   1. Removes bad WatchdogSec (kills CKB every N seconds — CKB doesn't use sd_notify)
#   2. Ensures service is enabled (survives reboots)
#   3. Sets Restart=always + RestartSec=15 (auto-reconnect/restart on any exit)
#   4. Sets StartLimitIntervalSec=0 (never stops retrying)
#   5. Sets LimitNOFILE=65536 (needed for many peer connections)
#   6. Adds a real application-level watchdog via a systemd timer:
#      Checks every 5 min that block height is advancing; restarts if stuck
#
# Non-destructive: all changes go into drop-in files, original service untouched.
#
# Usage:
#   sudo bash fix-ckb-watchdog.sh                       # local node
#   ssh user@host 'sudo bash -s' < fix-ckb-watchdog.sh  # remote node

set -e

SERVICE=/etc/systemd/system/ckb.service
OVERRIDE_DIR=/etc/systemd/system/ckb.service.d
OVERRIDE=$OVERRIDE_DIR/hardened.conf
WATCHDOG_SCRIPT=/usr/local/bin/ckb-watchdog
WATCHDOG_SERVICE=/etc/systemd/system/ckb-watchdog.service
WATCHDOG_TIMER=/etc/systemd/system/ckb-watchdog.timer
STATE_FILE=/var/lib/ckb/.watchdog-state

echo "=== CKB service hardening fix ==="
echo ""

if [ "$(id -u)" -ne 0 ]; then
    echo "Run as root (sudo bash fix-ckb-watchdog.sh)"
    exit 1
fi

if [ ! -f "$SERVICE" ]; then
    echo "ckb.service not found at $SERVICE"
    echo "Is CKB installed? Expected service file at $SERVICE"
    exit 1
fi

# ── Step 1: Drop-in override ─────────────────────────────────────────────────
echo "Step 1: Applying service drop-in..."
mkdir -p "$OVERRIDE_DIR"
cat > "$OVERRIDE" << 'EOF'
[Unit]
# Never stop trying to restart, regardless of how many failures occur
StartLimitIntervalSec=0

[Service]
# Restart on ANY exit (crash, OOM, manual kill) — not just on-failure
Restart=always
RestartSec=15

# CKB uses Type=simple and does NOT send sd_notify keepalive pings.
# WatchdogSec with Type=simple kills the process on a fixed interval
# even when it's healthy. Application-level watchdog handles this instead.
WatchdogSec=0

# Enough file descriptors for 50+ peers
LimitNOFILE=65536

# Give CKB 60s to shut down cleanly before SIGKILL
TimeoutStopSec=60
EOF
echo "  Drop-in written to $OVERRIDE"

# ── Step 2: Enable service (auto-start on boot) ───────────────────────────────
echo "Step 2: Ensuring service is enabled..."
if systemctl is-enabled ckb >/dev/null 2>&1; then
    echo "  ckb.service already enabled"
else
    systemctl enable ckb
    echo "  ckb.service enabled"
fi

# ── Step 3: Application-level watchdog script ────────────────────────────────
echo "Step 3: Installing application-level watchdog..."

# Detect RPC port (default 8114, override with CKB_RPC_PORT env)
CKB_RPC_PORT=${CKB_RPC_PORT:-8114}

cat > "$WATCHDOG_SCRIPT" << WDEOF
#!/bin/bash
# ckb-watchdog — Checks that CKB block height is advancing.
# Runs every 5 min via systemd timer. Restarts ckb.service if stuck.
#
# "Stuck" = block height hasn't changed in 10 minutes (2 consecutive checks).

STATE="$STATE_FILE"
RPC_PORT=\${CKB_RPC_PORT:-$CKB_RPC_PORT}
LOGPFX="ckb-watchdog:"

get_tip() {
    curl -sf --max-time 5 \
        -H "Content-Type: application/json" \
        -d '{"jsonrpc":"2.0","method":"get_tip_block_number","params":[],"id":1}' \
        "http://127.0.0.1:\${RPC_PORT}" 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(int(d['result'],16))" 2>/dev/null
}

mkdir -p "\$(dirname \$STATE)"
NOW=\$(date +%s)
HEIGHT=\$(get_tip)

if [ -z "\$HEIGHT" ]; then
    # RPC unreachable — service may be starting up
    echo "\$LOGPFX RPC unreachable on port \$RPC_PORT — skipping check"
    # If it's been unreachable for >10 min, restart
    if [ -f "\$STATE" ]; then
        LAST_OK=\$(grep "last_ok=" "\$STATE" 2>/dev/null | cut -d= -f2)
        if [ -n "\$LAST_OK" ] && [ \$(( NOW - LAST_OK )) -gt 600 ]; then
            echo "\$LOGPFX RPC down for >10 min — restarting ckb.service"
            systemctl restart ckb
            echo "last_ok=\$NOW" > "\$STATE"
            echo "last_height=0" >> "\$STATE"
        fi
    fi
    exit 0
fi

PREV_HEIGHT=\$(grep "last_height=" "\$STATE" 2>/dev/null | cut -d= -f2)
PREV_TIME=\$(grep "last_ok=" "\$STATE" 2>/dev/null | cut -d= -f2)

if [ -n "\$PREV_HEIGHT" ] && [ "\$HEIGHT" -eq "\$PREV_HEIGHT" ] && [ -n "\$PREV_TIME" ]; then
    STUCK_FOR=\$(( NOW - PREV_TIME ))
    echo "\$LOGPFX block height stuck at \$HEIGHT for \${STUCK_FOR}s"
    if [ \$STUCK_FOR -gt 600 ]; then
        echo "\$LOGPFX stuck >10 min — restarting ckb.service"
        systemctl restart ckb
        # Reset state
        echo "last_ok=\$NOW" > "\$STATE"
        echo "last_height=\$HEIGHT" >> "\$STATE"
    fi
else
    # Height advanced (or first run) — all good
    echo "\$LOGPFX block height \$HEIGHT (was \${PREV_HEIGHT:-n/a}) — healthy"
    echo "last_ok=\$NOW" > "\$STATE"
    echo "last_height=\$HEIGHT" >> "\$STATE"
fi
WDEOF

chmod +x "$WATCHDOG_SCRIPT"
echo "  Watchdog script written to $WATCHDOG_SCRIPT"

# ── Step 4: Watchdog systemd timer ───────────────────────────────────────────
echo "Step 4: Installing watchdog timer..."

cat > "$WATCHDOG_SERVICE" << 'EOF'
[Unit]
Description=CKB Application-Level Watchdog
After=ckb.service
Requires=ckb.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ckb-watchdog
EOF

cat > "$WATCHDOG_TIMER" << 'EOF'
[Unit]
Description=CKB Watchdog — check every 5 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
AccuracySec=30

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now ckb-watchdog.timer
echo "  Watchdog timer enabled and running"

# ── Step 5: Restart ckb if running ───────────────────────────────────────────
echo ""
echo "Step 5: Applying changes..."
systemctl daemon-reload

if systemctl is-active ckb >/dev/null 2>&1; then
    echo "  Restarting ckb.service to apply drop-in..."
    systemctl restart ckb
    sleep 3
    STATUS=$(systemctl is-active ckb)
    if [ "$STATUS" = "active" ]; then
        echo "  ckb.service is active"
    else
        echo "  WARNING: ckb.service did not start — check: journalctl -u ckb -n 20"
        exit 1
    fi
else
    echo "  ckb.service not running — changes take effect on next start"
    echo "  Start with: systemctl start ckb"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "=== Done ==="
echo "  Service enabled:       $(systemctl is-enabled ckb)"
echo "  Service status:        $(systemctl is-active ckb)"
echo "  Watchdog timer:        $(systemctl is-active ckb-watchdog.timer)"
echo ""
echo "Useful commands:"
echo "  journalctl -u ckb -f                  # follow node logs"
echo "  journalctl -u ckb-watchdog            # check watchdog history"
echo "  systemctl status ckb                  # service status"
