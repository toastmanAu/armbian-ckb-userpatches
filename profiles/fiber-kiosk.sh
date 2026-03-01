#!/bin/bash
# Profile: fiber-kiosk
# CKB full node + Fiber network node + XFCE desktop kiosk
# Requires: BUILD_DESKTOP=yes DESKTOP_ENVIRONMENT=xfce

FIBER_VERSION="${FIBER_VERSION:-0.7.0}"

# Inherit CKB node base
source "${OVERLAY}/profiles/ckb-node.sh"
_ckb_node_main() { profile_main; }

profile_main() {
    _ckb_node_main

    echo ">>> [fiber-kiosk] Installing Fiber node"

    # Download fiber binary
    local fiber_url="https://github.com/nervosnetwork/fiber/releases/download/v${FIBER_VERSION}/fnn-v${FIBER_VERSION}-aarch64-unknown-linux-gnu.tar.gz"
    [[ "$ARCH" == "amd64" ]] && fiber_url="https://github.com/nervosnetwork/fiber/releases/download/v${FIBER_VERSION}/fnn-v${FIBER_VERSION}-x86_64-unknown-linux-gnu.tar.gz"

    mkdir -p /opt/fiber
    curl -fsSL "$fiber_url" | tar -xz -C /opt/fiber --strip-components=1 || {
        echo ">>> [fiber-kiosk] WARNING: could not download fiber binary (will be installed on firstboot)"
    }
    [[ -f /opt/fiber/fnn ]] && ln -sf /opt/fiber/fnn /usr/local/bin/fnn

    # Fiber bridge (Node.js HTTP bridge to Fiber RPC)
    mkdir -p /opt/fiber-bridge
    cp -r "${OVERLAY}/usr/local/share/fiber-bridge/." /opt/fiber-bridge/
    cd /opt/fiber-bridge && npm install --production 2>/dev/null || true

    # Services
    install_file "etc/systemd/system/fiber-node.service" "/etc/systemd/system/fiber-node.service"
    install_file "etc/systemd/system/fiber-bridge.service" "/etc/systemd/system/fiber-bridge.service"
    enable_service fiber-node.service
    enable_service fiber-bridge.service

    # ── XFCE Desktop customisation ─────────────────────────────────────────

    echo ">>> [fiber-kiosk] Configuring XFCE desktop"

    # Install chromium for kiosk browser launches
    apt_install chromium

    # Icons
    install_file "usr/share/pixmaps/ckb-icon.png" "/usr/share/pixmaps/ckb-icon.png"
    install_file "usr/share/pixmaps/fiber-icon.png" "/usr/share/pixmaps/fiber-icon.png"

    # .desktop launchers
    install_file "usr/share/applications/ckb-dashboard.desktop" "/usr/share/applications/ckb-dashboard.desktop"
    install_file "usr/share/applications/fiber-ui.desktop" "/usr/share/applications/fiber-ui.desktop"
    install_file "usr/share/applications/ckb-status.desktop" "/usr/share/applications/ckb-status.desktop"

    # Pre-configure XFCE panel launchers for default user skeleton
    mkdir -p /etc/skel/.config/xfce4/panel
    install_file "etc/skel/.config/xfce4/panel/launcher-ckb.rc" "/etc/skel/.config/xfce4/panel/launcher-ckb.rc"
    install_file "etc/skel/.config/xfce4/panel/launcher-fiber.rc" "/etc/skel/.config/xfce4/panel/launcher-fiber.rc"
    install_file "etc/skel/.config/xfce4/xfce4-panel.xml" "/etc/skel/.config/xfce4/xfce4-panel.xml"

    # Status script (terminal pop-up from taskbar)
    install_file "usr/local/bin/ckb-status" "/usr/local/bin/ckb-status" 755

    cat >> /etc/motd << 'MOTD'

  ╔════════════════════════════════════════════╗
  ║   CKB + Fiber Kiosk — Wyltek Industries    ║
  ║   CKB Dashboard: http://<ip>:8080          ║
  ║   Fiber UI:      http://<ip>:9090          ║
  ║   Fiber RPC:     http://localhost:8227     ║
  ╚════════════════════════════════════════════╝

MOTD

    echo ">>> [fiber-kiosk] done"
}
