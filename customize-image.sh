#!/bin/bash
# CKB Armbian userpatches — customize-image.sh
# Runs inside the image chroot at build time.
# Drop this folder into armbian-build/userpatches/ and build normally.
#
# Usage:
#   CKB_PROFILE=ckb-node    bash compile.sh build BOARD=orangepi3b ...
#   CKB_PROFILE=solo-miner  bash compile.sh build BOARD=orangepi3b ...
#   CKB_PROFILE=fiber-kiosk bash compile.sh build BOARD=orangepi3b BUILD_DESKTOP=yes DESKTOP_ENVIRONMENT=xfce ...
#
# Profiles: ckb-node | solo-miner | fiber-kiosk | neuron-desktop

RELEASE=$1
LINUXFAMILY=$2
BOARD=$3
BUILD_DESKTOP=$4
ARCH=$5

OVERLAY=/tmp/overlay
CKB_PROFILE="${CKB_PROFILE:-ckb-node}"

echo ">>> CKB userpatches: profile=${CKB_PROFILE} board=${BOARD} arch=${ARCH} release=${RELEASE}"

# ── Helpers ───────────────────────────────────────────────────────────────────

install_file() {
    local src="${OVERLAY}/${1}" dest="${2}" mode="${3:-644}"
    mkdir -p "$(dirname "$dest")"
    cp "$src" "$dest"
    chmod "$mode" "$dest"
}

enable_service() { systemctl enable "$1" 2>/dev/null || true; }

apt_install() { DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$@"; }

# ── Architecture guard ────────────────────────────────────────────────────────

if [[ "$CKB_PROFILE" == "neuron-desktop" && "$ARCH" != "amd64" ]]; then
    echo ">>> ERROR: neuron-desktop requires amd64. Got: $ARCH"
    exit 1
fi

# ── Base packages (all profiles) ──────────────────────────────────────────────

apt_install curl wget jq git unzip bc

# ── Source and run profile ────────────────────────────────────────────────────

PROFILE_SCRIPT="${OVERLAY}/profiles/${CKB_PROFILE}.sh"
if [[ ! -f "$PROFILE_SCRIPT" ]]; then
    echo ">>> ERROR: unknown profile '${CKB_PROFILE}'"
    exit 1
fi

source "$PROFILE_SCRIPT"
profile_main

# ── Install firstboot wizard (all profiles) ───────────────────────────────────

install_file "firstboot/ckb-firstboot.sh" "/usr/local/bin/ckb-firstboot.sh" 755
install_file "firstboot/ckb-firstboot.service" "/etc/systemd/system/ckb-firstboot.service" 644
enable_service ckb-firstboot.service

echo ">>> CKB userpatches: done (profile=${CKB_PROFILE})"
