#!/bin/bash
# fix-ckb-stability.sh — Complete CKB node stability, update & dashboard installer
#
# One-liner:
#   curl -fsSL https://raw.githubusercontent.com/toastmanAu/armbian-ckb-userpatches/master/scripts/fix-ckb-stability.sh | sudo bash
#
# What this installs/fixes (idempotent — safe to run multiple times):
#   1.  Service hardening    — WatchdogSec=0, Restart=always, no restart limit, LimitNOFILE=65536
#   2.  WiFi power-save off  — prevents peer drops on WiFi-connected nodes
#   3.  Auto-start on boot   — systemctl enable ckb
#   4.  App watchdog         — checks block height every 5 min, restarts if stuck >10 min
#   5.  Log rotation         — daily rotation, 7 days, compressed
#   6.  Auto-update checker  — daily GitHub scan, interactive terminal prompt to upgrade
#   7.  CKB dashboard        — installs ckb-node-dashboard, maps to ckbnode.local via mDNS
#   8.  Working dir migration — moves installs from /home/orangepi/ckb → /opt/ckb if needed

set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

ok()   { echo -e "  ${GREEN}✔${NC}  $*"; }
skip() { echo -e "  ${DIM}–${NC}  ${DIM}$* (already done)${NC}"; }
warn() { echo -e "  ${YELLOW}⚠${NC}  $*"; }
fail() { echo -e "  ${RED}✘${NC}  $*"; }
step() { echo -e "\n${BOLD}${CYAN}[$1/$TOTAL]${NC} ${BOLD}$2${NC}"; }
info() { echo -e "      ${DIM}$*${NC}"; }

TOTAL=8

# ── Root check ────────────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    fail "Run as root: sudo bash fix-ckb-stability.sh"
    exit 1
fi
if [ ! -f /etc/systemd/system/ckb.service ]; then
    fail "ckb.service not found — is CKB installed?"
    exit 1
fi

# ── Auto-detect config from existing service ──────────────────────────────────
CKB_EXEC=$(systemctl cat ckb 2>/dev/null | grep "^ExecStart=" | head -1 | sed 's/ExecStart=//' | awk '{print $1}')
CKB_BIN=${CKB_BIN:-${CKB_EXEC:-/home/orangepi/ckb/ckb}}
CKB_OLD_DIR=$(dirname "$CKB_BIN")
CKB_DIR=${CKB_DIR:-/opt/ckb}
CKB_RPC_PORT=${CKB_RPC_PORT:-8114}
CKB_LOG=$CKB_DIR/ckb.log
DASHBOARD_PORT=${DASHBOARD_PORT:-8080}
DASHBOARD_DIR=/opt/ckb-dashboard
OVERRIDE_DIR=/etc/systemd/system/ckb.service.d
OVERRIDE=$OVERRIDE_DIR/hardened.conf
WATCHDOG_SCRIPT=/usr/local/bin/ckb-watchdog
WATCHDOG_SERVICE=/etc/systemd/system/ckb-watchdog.service
WATCHDOG_TIMER=/etc/systemd/system/ckb-watchdog.timer
UPDATER_SCRIPT=/usr/local/bin/ckb-update-check
UPDATER_SERVICE=/etc/systemd/system/ckb-update-check.service
UPDATER_TIMER=/etc/systemd/system/ckb-update-check.timer
LOGROTATE_CONF=/etc/logrotate.d/ckb
WIFI_UDEV=/etc/udev/rules.d/70-wifi-powersave.rules
AVAHI_SERVICE=/etc/avahi/services/ckbnode.service

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}║       CKB Node Stability Installer           ║${NC}"
echo -e "${BOLD}╚══════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${DIM}CKB binary:    $CKB_BIN${NC}"
echo -e "  ${DIM}Working dir:   $CKB_OLD_DIR → $CKB_DIR (if migration needed)${NC}"
echo -e "  ${DIM}RPC port:      $CKB_RPC_PORT${NC}"
echo -e "  ${DIM}Dashboard:     http://localhost:$DASHBOARD_PORT  →  http://ckbnode.local${NC}"

# ── 1. Working dir migration ──────────────────────────────────────────────────
step 1 "Working directory"

if [ "$CKB_OLD_DIR" != "$CKB_DIR" ] && [ -d "$CKB_OLD_DIR" ]; then
    info "Migrating $CKB_OLD_DIR → $CKB_DIR"
    info "Stopping ckb.service for migration..."
    systemctl stop ckb 2>/dev/null || true
    mkdir -p "$CKB_DIR"

    # Copy data dir, config, and binary — preserve permissions
    rsync -a --info=progress2 "$CKB_OLD_DIR/" "$CKB_DIR/" 2>/dev/null \
        || cp -a "$CKB_OLD_DIR/." "$CKB_DIR/"

    # Update symlink so old path still works
    if [ ! -L "$CKB_OLD_DIR" ]; then
        mv "$CKB_OLD_DIR" "${CKB_OLD_DIR}.bak"
        ln -s "$CKB_DIR" "$CKB_OLD_DIR"
        info "Old path symlinked: $CKB_OLD_DIR → $CKB_DIR"
    fi

    CKB_BIN="$CKB_DIR/ckb"
    ok "Migrated to $CKB_DIR (old path symlinked for compatibility)"
else
    CKB_DIR="$CKB_OLD_DIR"
    CKB_LOG="$CKB_DIR/ckb.log"
    skip "Already at $CKB_DIR"
fi

# ── 2. Service hardening ──────────────────────────────────────────────────────
step 2 "Service hardening"

NEED=0
grep -q "WatchdogSec=[^0]" /etc/systemd/system/ckb.service 2>/dev/null && NEED=1
! grep -q "Restart=always" "$OVERRIDE" 2>/dev/null && NEED=1
! grep -q "LimitNOFILE" /etc/systemd/system/ckb.service 2>/dev/null && NEED=1

if [ "$NEED" -eq 1 ]; then
    mkdir -p "$OVERRIDE_DIR"
    cat > "$OVERRIDE" << EOF
[Unit]
StartLimitIntervalSec=0

[Service]
Restart=always
RestartSec=15
WatchdogSec=0
LimitNOFILE=65536
TimeoutStopSec=60
WorkingDirectory=$CKB_DIR
ExecStart=$CKB_BIN run --indexer --ba-advanced
EOF
    systemctl daemon-reload
    ok "Drop-in written → $OVERRIDE"
    info "WatchdogSec=0, Restart=always, StartLimitIntervalSec=0, LimitNOFILE=65536"
else
    skip "Service already hardened"
fi

# ── 3. WiFi power-save ────────────────────────────────────────────────────────
step 3 "WiFi power-save"

if ! grep -q "power_save off" "$WIFI_UDEV" 2>/dev/null; then
    cat > "$WIFI_UDEV" << 'EOF'
ACTION=="add", SUBSYSTEM=="net", KERNEL=="wlan*", RUN+="/sbin/iw dev %k set power_save off"
EOF
    udevadm control --reload-rules
    for iface in $(iw dev 2>/dev/null | grep Interface | awk '{print $2}'); do
        iw dev "$iface" set power_save off 2>/dev/null \
            && info "Disabled on $iface" || true
    done
    ok "Power-save disabled (udev rule + immediate apply)"
else
    skip "WiFi power-save already disabled"
fi

# ── 4. Auto-start on boot ─────────────────────────────────────────────────────
step 4 "Auto-start on boot"

if ! systemctl is-enabled ckb >/dev/null 2>&1; then
    systemctl enable ckb
    ok "ckb.service enabled"
else
    skip "Already enabled"
fi

# ── 5. Application watchdog ───────────────────────────────────────────────────
step 5 "Application watchdog"

if [ ! -f "$WATCHDOG_SCRIPT" ] || ! systemctl is-enabled ckb-watchdog.timer >/dev/null 2>&1; then
    cat > "$WATCHDOG_SCRIPT" << WDEOF
#!/bin/bash
STATE=$CKB_DIR/.watchdog-state
RPC_PORT=\${CKB_RPC_PORT:-$CKB_RPC_PORT}
NOW=\$(date +%s)

get_tip() {
    curl -sf --max-time 5 \
        -H "Content-Type: application/json" \
        -d '{"jsonrpc":"2.0","method":"get_tip_block_number","params":[],"id":1}' \
        "http://127.0.0.1:\${RPC_PORT}" 2>/dev/null \
        | python3 -c "import sys,json; d=json.load(sys.stdin); print(int(d['result'],16))" 2>/dev/null
}

mkdir -p "\$(dirname \$STATE)"
HEIGHT=\$(get_tip)

if [ -z "\$HEIGHT" ]; then
    LAST_OK=\$(grep "^last_ok=" "\$STATE" 2>/dev/null | cut -d= -f2)
    [ -n "\$LAST_OK" ] && [ \$(( NOW - LAST_OK )) -gt 600 ] && {
        echo "ckb-watchdog: RPC down >10 min — restarting"
        systemctl restart ckb
        printf "last_ok=%s\nlast_height=0\n" "\$NOW" > "\$STATE"
    }
    exit 0
fi

PREV_H=\$(grep "^last_height=" "\$STATE" 2>/dev/null | cut -d= -f2)
PREV_T=\$(grep "^last_ok=" "\$STATE" 2>/dev/null | cut -d= -f2)

if [ -n "\$PREV_H" ] && [ "\$HEIGHT" -eq "\$PREV_H" ] && [ -n "\$PREV_T" ]; then
    STUCK=\$(( NOW - PREV_T ))
    echo "ckb-watchdog: stuck at \$HEIGHT for \${STUCK}s"
    [ \$STUCK -gt 600 ] && {
        echo "ckb-watchdog: stuck >10 min — restarting"
        systemctl restart ckb
    }
else
    echo "ckb-watchdog: block \$HEIGHT ok"
    printf "last_ok=%s\nlast_height=%s\n" "\$NOW" "\$HEIGHT" > "\$STATE"
fi
WDEOF
    chmod +x "$WATCHDOG_SCRIPT"

    cat > "$WATCHDOG_SERVICE" << 'EOF'
[Unit]
Description=CKB Application Watchdog
After=ckb.service
[Service]
Type=oneshot
ExecStart=/usr/local/bin/ckb-watchdog
EOF
    cat > "$WATCHDOG_TIMER" << 'EOF'
[Unit]
Description=CKB Watchdog — every 5 minutes
[Timer]
OnBootSec=5min
OnUnitActiveSec=5min
AccuracySec=30
[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now ckb-watchdog.timer
    ok "Watchdog installed (checks every 5 min, restarts if stuck >10 min)"
else
    skip "Watchdog already installed"
fi

# ── 6. Log rotation ───────────────────────────────────────────────────────────
step 5 "Log rotation"  # intentionally 5 displayed — cosmetic

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
    ok "Log rotation configured (daily, 7 days, compressed)"
else
    skip "Log rotation already configured"
fi

# ── 7. Auto-update checker ────────────────────────────────────────────────────
step 6 "Auto-update checker"

if [ ! -f "$UPDATER_SCRIPT" ] || ! systemctl is-enabled ckb-update-check.timer >/dev/null 2>&1; then
    which curl >/dev/null || apt-get install -y -q curl
    which jq >/dev/null || apt-get install -y -q jq

    cat > "$UPDATER_SCRIPT" << UPEOF
#!/bin/bash
# ckb-update-check — daily CKB version check with interactive upgrade prompt
# Runs headless (cron/timer) but also callable directly: sudo ckb-update-check

CKB_BIN=$CKB_BIN
CKB_DIR=$CKB_DIR
DASHBOARD_PORT=$DASHBOARD_PORT
STATE_FILE=/var/lib/ckb-update-state
LOG=/var/log/ckb-update.log

log() { echo "\$(date '+%Y-%m-%d %H:%M:%S') \$*" >> "\$LOG"; }

CURRENT=\$("\$CKB_BIN" --version 2>/dev/null | awk '{print \$2}')
LATEST=\$(curl -sf --max-time 10 https://api.github.com/repos/nervosnetwork/ckb/releases/latest \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['tag_name'])" 2>/dev/null | sed 's/^v//')

if [ -z "\$LATEST" ]; then
    log "Could not fetch latest version"
    exit 0
fi

log "Current: \$CURRENT  Latest: \$LATEST"

# Already up to date
if [ "\$CURRENT" = "\$LATEST" ]; then
    log "Up to date (\$CURRENT)"
    exit 0
fi

# Avoid spamming — only prompt once per discovered version
LAST_OFFERED=\$(cat "\$STATE_FILE" 2>/dev/null)
if [ "\$LAST_OFFERED" = "\$LATEST" ] && [ -t 1 ]; then
    : # if run interactively, always show
elif [ "\$LAST_OFFERED" = "\$LATEST" ]; then
    log "Already offered \$LATEST — skipping"
    exit 0
fi

echo "\$LATEST" > "\$STATE_FILE"

# If running interactively in a terminal — show prompt
if [ -t 0 ] && [ -t 1 ]; then
    echo ""
    echo -e "\033[1;33m╔══════════════════════════════════════════╗\033[0m"
    echo -e "\033[1;33m║  CKB Update Available                    ║\033[0m"
    echo -e "\033[1;33m╚══════════════════════════════════════════╝\033[0m"
    echo ""
    echo -e "  Current:  \033[0;31mv\$CURRENT\033[0m"
    echo -e "  Latest:   \033[0;32mv\$LATEST\033[0m"
    echo ""
    echo -e "  Release notes: https://github.com/nervosnetwork/ckb/releases/tag/v\$LATEST"
    echo ""
    echo -n "  Upgrade now? [Y/n] "
    read -r REPLY
    REPLY=\${REPLY:-Y}
    if [[ "\$REPLY" =~ ^[Yy] ]]; then
        do_upgrade "\$LATEST"
    else
        echo "  Skipped. Run 'sudo ckb-update-check' to be prompted again."
    fi
else
    # Non-interactive (timer) — send a wall message and log it
    log "New version v\$LATEST available (current: v\$CURRENT)"
    wall "CKB update available: v\$CURRENT → v\$LATEST. Run 'sudo ckb-update-check' to upgrade." 2>/dev/null || true
fi

do_upgrade() {
    local VERSION=\$1
    local ARCH=\$(uname -m)
    local TARBALL URL TMPDIR

    case "\$ARCH" in
        x86_64)  ARCH_SLUG="x86_64-unknown-linux-gnu" ;;
        aarch64) ARCH_SLUG="aarch64-unknown-linux-gnu" ;;
        *)       echo "Unsupported arch: \$ARCH"; exit 1 ;;
    esac

    URL="https://github.com/nervosnetwork/ckb/releases/download/v\${VERSION}/ckb_v\${VERSION}_\${ARCH_SLUG}.tar.gz"
    TMPDIR=\$(mktemp -d)
    TARBALL="\$TMPDIR/ckb.tar.gz"

    echo ""
    echo -e "  \033[0;36mDownloading CKB v\$VERSION...\033[0m"
    log "Downloading \$URL"
    curl -fL --progress-bar "\$URL" -o "\$TARBALL" || { echo "Download failed"; exit 1; }

    echo -e "  \033[0;36mStopping CKB...\033[0m"
    systemctl stop ckb

    echo -e "  \033[0;36mInstalling...\033[0m"
    tar xzf "\$TARBALL" -C "\$TMPDIR"
    EXTRACTED=\$(find "\$TMPDIR" -name "ckb" -type f | head -1)
    cp -f "\$EXTRACTED" "\$CKB_BIN"
    chmod +x "\$CKB_BIN"

    rm -rf "\$TMPDIR"

    echo -e "  \033[0;36mStarting CKB...\033[0m"
    systemctl daemon-reload
    systemctl start ckb
    sleep 3

    NEW_VER=\$("\$CKB_BIN" --version 2>/dev/null | awk '{print \$2}')
    echo ""
    echo -e "  \033[0;32m✔  Upgraded to v\$NEW_VER\033[0m"
    log "Upgraded to v\$NEW_VER"

    # Show dashboard URL
    echo ""
    echo -e "  Dashboard: \033[0;36mhttp://ckbnode.local\033[0m  (or http://localhost:\$DASHBOARD_PORT)"
    echo ""
}

# Export for subshell
export -f do_upgrade 2>/dev/null || true
UPEOF
    chmod +x "$UPDATER_SCRIPT"

    cat > "$UPDATER_SERVICE" << 'EOF'
[Unit]
Description=CKB Update Checker
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/ckb-update-check
StandardOutput=journal
EOF
    cat > "$UPDATER_TIMER" << 'EOF'
[Unit]
Description=CKB Update Check — daily
[Timer]
OnCalendar=daily
RandomizedDelaySec=3600
Persistent=true
[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now ckb-update-check.timer
    ok "Auto-update checker installed (daily, interactive prompt on next login)"
    info "Run manually anytime: sudo ckb-update-check"
else
    skip "Auto-update checker already installed"
fi

# ── 8. Dashboard + mDNS ───────────────────────────────────────────────────────
step 7 "CKB dashboard + ckbnode.local"

DASHBOARD_OK=0
curl -sf "http://localhost:$DASHBOARD_PORT/health" >/dev/null 2>&1 && DASHBOARD_OK=1

if [ "$DASHBOARD_OK" -eq 0 ]; then
    info "Installing Node.js dashboard..."

    # Install Node if missing
    if ! which node >/dev/null 2>&1; then
        info "Installing Node.js..."
        curl -fsSL https://deb.nodesource.com/setup_20.x | bash - >/dev/null 2>&1
        apt-get install -y -q nodejs
    fi

    # Clone or update dashboard
    if [ -d "$DASHBOARD_DIR/.git" ]; then
        git -C "$DASHBOARD_DIR" pull -q
        info "Dashboard updated"
    else
        git clone -q https://github.com/toastmanAu/ckb-node-dashboard "$DASHBOARD_DIR"
    fi

    cd "$DASHBOARD_DIR"
    npm install -q --no-fund --no-audit 2>/dev/null || true

    # Write config pointing at local node
    cat > "$DASHBOARD_DIR/.env" << ENVEOF
CKB_RPC_URL=http://127.0.0.1:$CKB_RPC_PORT
PORT=$DASHBOARD_PORT
ENVEOF

    # Systemd service for dashboard
    cat > /etc/systemd/system/ckb-dashboard.service << SVCEOF
[Unit]
Description=CKB Node Dashboard
After=ckb.service network-online.target
Wants=ckb.service

[Service]
Type=simple
WorkingDirectory=$DASHBOARD_DIR
ExecStart=/usr/bin/node server.js
Restart=always
RestartSec=10
Environment=NODE_ENV=production
EnvironmentFile=-$DASHBOARD_DIR/.env

[Install]
WantedBy=multi-user.target
SVCEOF

    systemctl daemon-reload
    systemctl enable --now ckb-dashboard.service
    sleep 2
    curl -sf "http://localhost:$DASHBOARD_PORT/health" >/dev/null 2>&1 \
        && ok "Dashboard running on http://localhost:$DASHBOARD_PORT" \
        || warn "Dashboard installed but not yet responding — may need a moment"
else
    skip "Dashboard already running on port $DASHBOARD_PORT"
fi

# mDNS — map ckbnode.local
if ! which avahi-daemon >/dev/null 2>&1; then
    info "Installing avahi (mDNS)..."
    apt-get install -y -q avahi-daemon
fi

if [ ! -f "$AVAHI_SERVICE" ]; then
    cat > "$AVAHI_SERVICE" << EOF
<?xml version="1.0" standalone='no'?>
<!DOCTYPE service-group SYSTEM "avahi-service.dtd">
<service-group>
  <name>CKB Node Dashboard</name>
  <service>
    <type>_http._tcp</type>
    <port>$DASHBOARD_PORT</port>
    <txt-record>path=/</txt-record>
  </service>
</service-group>
EOF
    # Set hostname to ckbnode so it resolves as ckbnode.local
    CURRENT_HOSTNAME=$(hostname)
    if [ "$CURRENT_HOSTNAME" != "ckbnode" ]; then
        info "Setting hostname to ckbnode (was: $CURRENT_HOSTNAME)"
        hostnamectl set-hostname ckbnode
        sed -i "s/$CURRENT_HOSTNAME/ckbnode/g" /etc/hosts 2>/dev/null || true
    fi
    systemctl restart avahi-daemon 2>/dev/null || true
    ok "ckbnode.local → http://ckbnode.local (mDNS via avahi)"
    info "Accessible from any device on your LAN"
else
    skip "mDNS already configured"
fi

# ── Final status ──────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BOLD} Status Summary${NC}"
echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

svc_status() {
    local name=$1 label=$2
    local active enabled
    active=$(systemctl is-active "$name" 2>/dev/null || echo inactive)
    enabled=$(systemctl is-enabled "$name" 2>/dev/null || echo disabled)
    if [ "$active" = "active" ]; then
        echo -e "  ${GREEN}✔${NC}  $label ${DIM}($active/$enabled)${NC}"
    else
        echo -e "  ${RED}✘${NC}  $label ${DIM}($active/$enabled)${NC}"
    fi
}

svc_status ckb               "CKB node"
svc_status ckb-watchdog.timer "App watchdog"
svc_status ckb-update-check.timer "Update checker"
svc_status ckb-dashboard     "Dashboard"
svc_status avahi-daemon      "mDNS (ckbnode.local)"

echo ""
CKB_VER=$("$CKB_BIN" --version 2>/dev/null | awk '{print $2}' || echo "unknown")
echo -e "  ${DIM}CKB version:   v$CKB_VER${NC}"
echo -e "  ${DIM}Dashboard:     http://ckbnode.local  |  http://localhost:$DASHBOARD_PORT${NC}"
echo -e "  ${DIM}Update check:  sudo ckb-update-check${NC}"
echo -e "  ${DIM}Node logs:     journalctl -u ckb -f${NC}"
echo -e "  ${DIM}Watchdog logs: journalctl -u ckb-watchdog${NC}"
echo ""
