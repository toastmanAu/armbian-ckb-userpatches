#!/bin/bash
# fix-ckb-stability.sh — Complete stability fix for manually-installed CKB nodes
#
# Covers every patch applied to production nodes since initial setup:
#
#   1. Service hardening drop-in (WatchdogSec=0, Restart=always, no restart limit,
#      LimitNOFILE=65536, clean shutdown timeout)
#   2. WiFi power-save disabled (udev rule + immediate apply via iw)
#   3. systemctl enable ckb (survive reboots)
#   4. Application-level watchdog (systemd timer, checks block height every 5 min)
#   5. Log rotation for /home/orangepi/ckb/ckb.log
#
# Non-destructive: uses drop-in files, does not modify original service file.
# Safe to run multiple times (idempotent).
#
# Usage:
#   sudo bash fix-ckb-stability.sh
#   ssh orangepi@<node-ip> 'sudo bash -s' < fix-ckb-stability.sh

set -e

# ── Config (auto-detected, override if needed) ────────────────────────────────
CKB_BIN=${CKB_BIN:-$(systemctl cat ckb 2>/dev/null | grep ExecStart | head -1 | awk '{print $2}')}
CKB_BIN=${CKB_BIN:-/home/orangepi/ckb/ckb}
CKB_DIR=${CKB_DIR:-$(dirname "$CKB_BIN")}
CKB_LOG=${CKB_LOG:-$CKB_DIR/ckb.log}
CKB_RPC_PORT=${CKB_RPC_PORT:-8114}
CKB_SERVICE_USER=${CKB_SERVICE_USER:-$(systemctl cat ckb 2>/dev/null | grep "^User=" | cut -d= -f2 || echo "root")}

OVERRIDE_DIR=/etc/systemd/system/ckb.service.d
OVERRIDE=$OVERRIDE_DIR/hardened.conf
WATCHDOG_SCRIPT=/usr/local/bin/ckb-watchdog
WATCHDOG_SERVICE=/etc/systemd/system/ckb-watchdog.service
WATCHDOG_TIMER=/etc/systemd/system/ckb-watchdog.timer
WATCHDOG_STATE=$CKB_DIR/.watchdog-state
LOGROTATE_CONF=/etc/logrotate.d/ckb
WIFI_UDEV=/etc/udev/rules.d/70-wifi-powersave.rules

FIXED=0

echo "========================================"
echo " CKB Node Stability Fix"
echo "========================================"
echo " CKB binary:  $CKB_BIN"
echo " CKB dir:     $CKB_DIR"
echo " CKB log:     $CKB_LOG"
echo " RPC port:    $CKB_RPC_PORT"
echo " Service user: $CKB_SERVICE_USER"
echo "========================================"
echo ""

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: Run as root (sudo bash fix-ckb-stability.sh)"
    exit 1
fi

if [ ! -f /etc/systemd/system/ckb.service ]; then
    echo "ERROR: ckb.service not found — is CKB installed?"
    exit 1
fi

# ── 1. Service hardening drop-in ──────────────────────────────────────────────
echo "[ 1/5 ] Service hardening..."

NEED_DROPIN=0
grep -q "WatchdogSec=[^0]" /etc/systemd/system/ckb.service && NEED_DROPIN=1
grep -q "StartLimitBurst=[^0]" /etc/systemd/system/ckb.service && NEED_DROPIN=1
! grep -q "LimitNOFILE" /etc/systemd/system/ckb.service && NEED_DROPIN=1
! [ -f "$OVERRIDE" ] && NEED_DROPIN=1

if [ "$NEED_DROPIN" -eq 1 ] || ! grep -q "Restart=always" "$OVERRIDE" 2>/dev/null; then
    mkdir -p "$OVERRIDE_DIR"
    cat > "$OVERRIDE" << 'EOF'
[Unit]
# Never give up restarting regardless of how many failures occur
StartLimitIntervalSec=0

[Service]
# Restart on ANY exit: crash, OOM, kill signal, anything
Restart=always
RestartSec=15

# CKB uses Type=simple and does NOT send sd_notify keepalive pings.
# WatchdogSec kills the process on a fixed timer even when healthy.
# The ckb-watchdog timer provides real application-level health checking.
WatchdogSec=0

# Enough file descriptors for 50+ peers + indexer + SQLite
LimitNOFILE=65536

# Give CKB time to flush its database cleanly before SIGKILL
TimeoutStopSec=60
EOF
    echo "     Drop-in written to $OVERRIDE"
    FIXED=1
else
    echo "     Already hardened — skipping"
fi

# ── 2. WiFi power-save ────────────────────────────────────────────────────────
echo "[ 2/5 ] WiFi power-save..."

if [ ! -f "$WIFI_UDEV" ] || ! grep -q "power_save off" "$WIFI_UDEV"; then
    cat > "$WIFI_UDEV" << 'EOF'
# Disable WiFi power management — prevents peer drop and sync stalls on CKB nodes
ACTION=="add", SUBSYSTEM=="net", KERNEL=="wlan*", RUN+="/sbin/iw dev %k set power_save off"
EOF
    udevadm control --reload-rules
    # Apply immediately to any active wireless interfaces
    for iface in $(iw dev 2>/dev/null | grep Interface | awk '{print $2}'); do
        iw dev "$iface" set power_save off 2>/dev/null && echo "     Disabled power-save on $iface" || true
    done
    echo "     WiFi power-save disabled (udev rule written)"
    FIXED=1
else
    echo "     Already set — skipping"
fi

# ── 3. Enable service ─────────────────────────────────────────────────────────
echo "[ 3/5 ] Enabling ckb.service..."

if ! systemctl is-enabled ckb >/dev/null 2>&1; then
    systemctl enable ckb
    echo "     ckb.service enabled (will start on boot)"
    FIXED=1
else
    echo "     Already enabled — skipping"
fi

# ── 4. Application-level watchdog ────────────────────────────────────────────
echo "[ 4/5 ] Application-level watchdog..."

NEED_WATCHDOG=0
[ ! -f "$WATCHDOG_SCRIPT" ] && NEED_WATCHDOG=1
[ ! -f "$WATCHDOG_TIMER" ] && NEED_WATCHDOG=1
! systemctl is-enabled ckb-watchdog.timer >/dev/null 2>&1 && NEED_WATCHDOG=1

if [ "$NEED_WATCHDOG" -eq 1 ]; then
    cat > "$WATCHDOG_SCRIPT" << WDEOF
#!/bin/bash
# ckb-watchdog — application-level health check
# Checks block height via RPC every 5 min; restarts ckb.service if stuck >10 min.

STATE="$WATCHDOG_STATE"
RPC_PORT=\${CKB_RPC_PORT:-$CKB_RPC_PORT}
LOGPFX="ckb-watchdog:"

get_tip() {
    curl -sf --max-time 5 \\
        -H "Content-Type: application/json" \\
        -d '{"jsonrpc":"2.0","method":"get_tip_block_number","params":[],"id":1}' \\
        "http://127.0.0.1:\${RPC_PORT}" 2>/dev/null \\
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(int(d['result'],16))" 2>/dev/null
}

mkdir -p "\$(dirname \$STATE)"
NOW=\$(date +%s)
HEIGHT=\$(get_tip)

if [ -z "\$HEIGHT" ]; then
    echo "\$LOGPFX RPC unreachable on port \$RPC_PORT"
    if [ -f "\$STATE" ]; then
        LAST_OK=\$(grep "^last_ok=" "\$STATE" 2>/dev/null | cut -d= -f2)
        if [ -n "\$LAST_OK" ] && [ \$(( NOW - LAST_OK )) -gt 600 ]; then
            echo "\$LOGPFX RPC down >10 min — restarting ckb.service"
            systemctl restart ckb
            printf "last_ok=%s\nlast_height=0\n" "\$NOW" > "\$STATE"
        fi
    fi
    exit 0
fi

PREV_HEIGHT=\$(grep "^last_height=" "\$STATE" 2>/dev/null | cut -d= -f2)
PREV_TIME=\$(grep "^last_ok=" "\$STATE" 2>/dev/null | cut -d= -f2)

if [ -n "\$PREV_HEIGHT" ] && [ "\$HEIGHT" -eq "\$PREV_HEIGHT" ] && [ -n "\$PREV_TIME" ]; then
    STUCK_FOR=\$(( NOW - PREV_TIME ))
    echo "\$LOGPFX stuck at block \$HEIGHT for \${STUCK_FOR}s"
    if [ \$STUCK_FOR -gt 600 ]; then
        echo "\$LOGPFX stuck >10 min — restarting ckb.service"
        systemctl restart ckb
        printf "last_ok=%s\nlast_height=%s\n" "\$NOW" "\$HEIGHT" > "\$STATE"
    fi
else
    echo "\$LOGPFX block \$HEIGHT (was \${PREV_HEIGHT:-n/a}) — ok"
    printf "last_ok=%s\nlast_height=%s\n" "\$NOW" "\$HEIGHT" > "\$STATE"
fi
WDEOF
    chmod +x "$WATCHDOG_SCRIPT"

    cat > "$WATCHDOG_SERVICE" << 'EOF'
[Unit]
Description=CKB Application-Level Watchdog
After=ckb.service

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
    echo "     Watchdog installed and running"
    FIXED=1
else
    echo "     Already installed — skipping"
fi

# ── 5. Log rotation ───────────────────────────────────────────────────────────
echo "[ 5/5 ] Log rotation..."

if [ ! -f "$LOGROTATE_CONF" ]; then
    cat > "$LOGROTATE_CONF" << LREOF
$CKB_LOG {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
LREOF
    echo "     logrotate config written"
    FIXED=1
else
    echo "     Already configured — skipping"
fi

# ── Apply & summarise ─────────────────────────────────────────────────────────
echo ""
if [ "$FIXED" -eq 1 ]; then
    echo "Applying changes (daemon-reload + restart)..."
    systemctl daemon-reload
    if systemctl is-active ckb >/dev/null 2>&1; then
        systemctl restart ckb
        sleep 3
    fi
fi

echo ""
echo "========================================"
echo " Status"
echo "========================================"
printf "  ckb.service:          %s (%s)\n" \
    "$(systemctl is-active ckb)" \
    "$(systemctl is-enabled ckb)"
printf "  ckb-watchdog.timer:   %s (%s)\n" \
    "$(systemctl is-active ckb-watchdog.timer 2>/dev/null || echo inactive)" \
    "$(systemctl is-enabled ckb-watchdog.timer 2>/dev/null || echo disabled)"
printf "  WiFi power-save:      %s\n" \
    "$(cat /sys/class/net/wlan0/power/wakeup 2>/dev/null || iw dev 2>/dev/null | grep -q wlan && echo 'rule set' || echo 'n/a (ethernet?)')"
printf "  Log rotation:         %s\n" \
    "$([ -f "$LOGROTATE_CONF" ] && echo 'configured' || echo 'missing')"
echo "========================================"
echo ""
echo "Useful commands:"
echo "  journalctl -u ckb -f                 # follow node logs"
echo "  journalctl -u ckb-watchdog           # watchdog history"
echo "  systemctl status ckb                 # full service status"
echo "  curl -s http://localhost:$CKB_RPC_PORT -d '{\"id\":1,\"jsonrpc\":\"2.0\",\"method\":\"get_tip_block_number\",\"params\":[]}' -H 'Content-Type: application/json'"
