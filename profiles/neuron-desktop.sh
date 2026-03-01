#!/bin/bash
# Profile: neuron-desktop
# CKB full node + Neuron wallet (x86/amd64 only) + XFCE desktop
# Requires: ARCH=amd64, BUILD_DESKTOP=yes DESKTOP_ENVIRONMENT=xfce

NEURON_VERSION="${NEURON_VERSION:-0.204.0}"

# Inherit CKB node base
source "${OVERLAY}/profiles/ckb-node.sh"
_ckb_node_main() { profile_main; }

profile_main() {
    _ckb_node_main

    echo ">>> [neuron-desktop] Installing Neuron wallet"

    apt_install libfuse2  # AppImage requirement

    local neuron_url="https://github.com/nervosnetwork/neuron/releases/download/v${NEURON_VERSION}/Neuron-v${NEURON_VERSION}-x86_64.AppImage"
    curl -fsSL -o /opt/Neuron.AppImage "$neuron_url"
    chmod +x /opt/Neuron.AppImage
    ln -sf /opt/Neuron.AppImage /usr/local/bin/neuron

    # Icons
    install_file "usr/share/pixmaps/ckb-icon.png" "/usr/share/pixmaps/ckb-icon.png"
    install_file "usr/share/pixmaps/neuron-icon.png" "/usr/share/pixmaps/neuron-icon.png"

    # .desktop launchers
    install_file "usr/share/applications/ckb-dashboard.desktop" "/usr/share/applications/ckb-dashboard.desktop"
    install_file "usr/share/applications/neuron.desktop" "/usr/share/applications/neuron.desktop"
    install_file "usr/share/applications/ckb-status.desktop" "/usr/share/applications/ckb-status.desktop"

    # XFCE panel config
    mkdir -p /etc/skel/.config/xfce4/panel
    install_file "etc/skel/.config/xfce4/panel/launcher-ckb.rc" "/etc/skel/.config/xfce4/panel/launcher-ckb.rc"
    install_file "etc/skel/.config/xfce4/panel/launcher-neuron.rc" "/etc/skel/.config/xfce4/panel/launcher-neuron.rc"
    install_file "etc/skel/.config/xfce4/xfce4-panel.xml" "/etc/skel/.config/xfce4/xfce4-panel.xml"

    install_file "usr/local/bin/ckb-status" "/usr/local/bin/ckb-status" 755

    cat >> /etc/motd << 'MOTD'

  ╔════════════════════════════════════════════╗
  ║   CKB + Neuron Desktop — Wyltek Industries ║
  ║   Dashboard: http://<ip>:8080              ║
  ║   Neuron:    launch from desktop           ║
  ╚════════════════════════════════════════════╝

MOTD

    echo ">>> [neuron-desktop] done"
}
