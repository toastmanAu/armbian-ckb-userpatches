#!/bin/bash
# Profile: ckb-node
# Headless CKB full node + dashboard + stratum proxy

CKB_VERSION="${CKB_VERSION:-0.204.0}"
NODE_VERSION="${NODE_VERSION:-20}"

profile_main() {
    echo ">>> [ckb-node] Installing CKB full node stack"

    # Node.js (for dashboard)
    curl -fsSL https://deb.nodesource.com/setup_${NODE_VERSION}.x | bash -
    apt_install nodejs

    # Download CKB binary
    local ckb_url="https://github.com/nervosnetwork/ckb/releases/download/v${CKB_VERSION}/ckb_v${CKB_VERSION}_aarch64-unknown-linux-gnu.tar.gz"
    [[ "$ARCH" == "amd64" ]] && ckb_url="https://github.com/nervosnetwork/ckb/releases/download/v${CKB_VERSION}/ckb_v${CKB_VERSION}_x86_64-unknown-linux-gnu.tar.gz"

    mkdir -p /opt/ckb
    curl -fsSL "$ckb_url" | tar -xz -C /opt/ckb --strip-components=1
    ln -sf /opt/ckb/ckb /usr/local/bin/ckb
    ln -sf /opt/ckb/ckb-cli /usr/local/bin/ckb-cli

    # Init CKB mainnet config
    mkdir -p /var/lib/ckb
    cd /var/lib/ckb && ckb init --chain mainnet --force

    # Dashboard (from overlay — pre-built)
    mkdir -p /opt/ckb-dashboard
    cp -r "${OVERLAY}/usr/local/share/ckb-dashboard/." /opt/ckb-dashboard/
    cd /opt/ckb-dashboard && npm install --production 2>/dev/null || true

    # Stratum proxy
    mkdir -p /opt/ckb-stratum
    cp -r "${OVERLAY}/usr/local/share/ckb-stratum/." /opt/ckb-stratum/
    cd /opt/ckb-stratum && npm install --production 2>/dev/null || true

    # Health check script
    install_file "usr/local/bin/ckb-health-check" "/usr/local/bin/ckb-health-check" 755

    # Services
    install_file "etc/systemd/system/ckb.service" "/etc/systemd/system/ckb.service"
    install_file "etc/systemd/system/ckb-dashboard.service" "/etc/systemd/system/ckb-dashboard.service"
    install_file "etc/systemd/system/ckb-stratum.service" "/etc/systemd/system/ckb-stratum.service"
    install_file "etc/systemd/system/ckb-health-check.service" "/etc/systemd/system/ckb-health-check.service"
    install_file "etc/systemd/system/ckb-health-check.timer" "/etc/systemd/system/ckb-health-check.timer"

    enable_service ckb.service
    enable_service ckb-dashboard.service
    enable_service ckb-health-check.timer

    # motd hint
    cat >> /etc/motd << 'MOTD'

  ╔═══════════════════════════════════════╗
  ║   CKB Node — Wyltek Industries        ║
  ║   Dashboard:  http://<ip>:8080        ║
  ║   RPC:        http://localhost:8114   ║
  ╚═══════════════════════════════════════╝

MOTD

    echo ">>> [ckb-node] done"
}
