#!/bin/bash
# Profile: neuron-desktop
# CKB full node + Neuron wallet + XFCE desktop
#
# arm64: uses custom arm64 AppImage build (PR #3441 / toastmanAu fork)
#        until official Neuron releases include arm64, pulls from fork releases
# amd64: uses official Neuron AppImage from nervosnetwork/neuron releases

NEURON_VERSION="${NEURON_VERSION:-0.204.0}"

# Official release (x86_64)
NEURON_X64_URL="https://github.com/nervosnetwork/neuron/releases/download/v${NEURON_VERSION}/Neuron-v${NEURON_VERSION}-x86_64.AppImage"

# arm64 build from toastmanAu fork (until PR #3441 merges upstream)
# Update this URL when upstream cuts an official arm64 release
NEURON_ARM64_URL="https://github.com/toastmanAu/neuron/releases/download/v${NEURON_VERSION}-arm64/Neuron-v${NEURON_VERSION}-arm64.AppImage"

# Inherit CKB node base
source "${OVERLAY}/profiles/ckb-node.sh"
_ckb_node_main() { profile_main; }

profile_main() {
    _ckb_node_main

    echo ">>> [neuron-desktop] Installing Neuron wallet (arch: ${ARCH})"

    # libfuse2 required by AppImage runtime; zlib1g-dev for libz.so on minimal images
    apt_install libfuse2 zlib1g-dev

    if [[ "$ARCH" == "amd64" ]]; then
        curl -fsSL -o /opt/Neuron.AppImage "$NEURON_X64_URL"
    elif [[ "$ARCH" == "arm64" ]]; then
        # Try fork release; fall back to firstboot download if unavailable
        if curl -fsSL -o /opt/Neuron.AppImage "$NEURON_ARM64_URL" 2>/dev/null; then
            echo ">>> [neuron-desktop] arm64 AppImage downloaded from fork release"
        else
            echo ">>> [neuron-desktop] WARNING: arm64 AppImage not in fork releases yet"
            echo ">>> Will be downloaded on firstboot, or build manually from PR #3441"
            # Leave a marker so firstboot wizard can handle it
            touch /opt/Neuron.AppImage.pending
        fi
        # SwiftShader fallback flag for BSP kernels (no GPU driver)
        echo "NEURON_FLAGS=--disable-gpu" >> /etc/ckb/node.env.template
    else
        echo ">>> ERROR: unsupported architecture for neuron-desktop: $ARCH"
        exit 1
    fi

    [[ -f /opt/Neuron.AppImage ]] && chmod +x /opt/Neuron.AppImage
    ln -sf /opt/Neuron.AppImage /usr/local/bin/neuron 2>/dev/null || true

    # Icons
    install_file "usr/share/pixmaps/ckb-icon.png" "/usr/share/pixmaps/ckb-icon.png"
    install_file "usr/share/pixmaps/neuron-icon.png" "/usr/share/pixmaps/neuron-icon.png"

    # .desktop launchers
    install_file "usr/share/applications/ckb-dashboard.desktop" "/usr/share/applications/ckb-dashboard.desktop"
    install_file "usr/share/applications/neuron.desktop" "/usr/share/applications/neuron.desktop"
    install_file "usr/share/applications/ckb-status.desktop" "/usr/share/applications/ckb-status.desktop"

    # XFCE panel config
    mkdir -p /etc/skel/.config/xfce4/panel
    install_file "etc/skel/.config/xfce4/panel/launcher-ckb.rc" "/etc/skel/.config/xfce4/panel/launcher-ckb.rc" 2>/dev/null || true
    install_file "etc/skel/.config/xfce4/panel/launcher-neuron.rc" "/etc/skel/.config/xfce4/panel/launcher-neuron.rc" 2>/dev/null || true
    install_file "etc/skel/.config/xfce4/xfce4-panel.xml" "/etc/skel/.config/xfce4/xfce4-panel.xml" 2>/dev/null || true

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
