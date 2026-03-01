#!/bin/bash
# CKB First-Boot Wizard
# Runs once on first login, configures the node for this specific device.
# Self-disables on completion.

PROFILE_FILE="/etc/ckb/profile"
CONFIG_FILE="/etc/ckb/node.env"
CKB_TOML="/var/lib/ckb/ckb.toml"

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; NC='\033[0m'; BOLD='\033[1m'

[[ -f "$CONFIG_FILE" ]] && { echo "First-boot already completed."; exit 0; }

PROFILE=$(cat "$PROFILE_FILE" 2>/dev/null || echo "ckb-node")

clear
echo -e "${CYAN}"
cat << 'BANNER'
  ██╗    ██╗██╗   ██╗██╗  ████████╗███████╗██╗  ██╗
  ██║    ██║╚██╗ ██╔╝██║  ╚══██╔══╝██╔════╝██║ ██╔╝
  ██║ █╗ ██║ ╚████╔╝ ██║     ██║   █████╗  █████╔╝
  ██║███╗██║  ╚██╔╝  ██║     ██║   ██╔══╝  ██╔═██╗
  ╚███╔███╔╝   ██║   ███████╗██║   ███████╗██║  ██╗
   ╚══╝╚══╝    ╚═╝   ╚══════╝╚═╝   ╚══════╝╚═╝  ╚═╝
BANNER
echo -e "${NC}"
echo -e "${BOLD}  CKB Node Setup — Wyltek Industries${NC}"
echo -e "  Profile: ${CYAN}${PROFILE}${NC}"
echo ""

mkdir -p /etc/ckb

# ── CKB Node ─────────────────────────────────────────────────────────────────

if [[ "$PROFILE" != "solo-miner" ]]; then
    echo -e "${BOLD}Starting CKB node...${NC}"
    systemctl start ckb || true
    systemctl start ckb-dashboard || true
    echo ""
fi

# ── Solo Miner: reward address ────────────────────────────────────────────────

if [[ "$PROFILE" == "solo-miner" ]]; then
    echo -e "${YELLOW}Solo mining setup — you'll need a CKB wallet address for rewards.${NC}"
    echo ""
    read -rp "  Enter your CKB reward address: " REWARD_ADDR
    while [[ -z "$REWARD_ADDR" ]]; do
        echo "  Address cannot be empty."
        read -rp "  Enter your CKB reward address: " REWARD_ADDR
    done

    # Write stratum config
    cat > /etc/stratum/config.json << STRATUMCFG
{
  "mode": "solo",
  "ckb_rpc": "http://localhost:8114",
  "stratum_port": 3333,
  "stats_port": 8081,
  "reward_address": "${REWARD_ADDR}"
}
STRATUMCFG

    echo "REWARD_ADDRESS=${REWARD_ADDR}" >> "$CONFIG_FILE"
    systemctl start ckb ckb-dashboard ckb-stratum || true
    echo ""
    echo -e "  ${GREEN}✓${NC} Stratum proxy configured. Point your miner at: ${CYAN}stratum+tcp://$(hostname -I | awk '{print $1}'):3333${NC}"
fi

# ── Fiber: key generation ─────────────────────────────────────────────────────

if [[ "$PROFILE" == "fiber-kiosk" ]]; then
    echo -e "${BOLD}Setting up Fiber network node...${NC}"
    echo ""

    # Generate random secret key password
    FIBER_KEY_PASSWORD=$(openssl rand -hex 16)
    mkdir -p /var/lib/fiber

    # Init fiber with generated key
    if command -v fnn &>/dev/null; then
        fnn init --dir /var/lib/fiber --password "$FIBER_KEY_PASSWORD" 2>/dev/null || true
    fi

    echo "FIBER_KEY_PASSWORD=${FIBER_KEY_PASSWORD}" >> "$CONFIG_FILE"

    systemctl start fiber-node fiber-bridge || true

    echo ""
    echo -e "  ${GREEN}✓${NC} Fiber node initialised"
    echo -e "  ${YELLOW}Key password saved to ${CONFIG_FILE} — back this up!${NC}"

    # Show generated wallet address
    sleep 2
    FIBER_ADDR=$(curl -sf http://localhost:8227 -X POST \
        -H 'Content-Type: application/json' \
        -d '{"jsonrpc":"2.0","method":"get_node_info","params":[],"id":1}' \
        2>/dev/null | jq -r '.result.addresses[0].address // "generating..."')
    echo -e "  Fiber address: ${CYAN}${FIBER_ADDR}${NC}"
    echo -e "  ${YELLOW}Fund this address with 100+ CKB to accept channels.${NC}"
fi

# ── Save profile marker ───────────────────────────────────────────────────────

echo "PROFILE=${PROFILE}" >> "$CONFIG_FILE"
echo "SETUP_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$CONFIG_FILE"
chmod 600 "$CONFIG_FILE"

# ── Self-disable ──────────────────────────────────────────────────────────────

systemctl disable ckb-firstboot.service 2>/dev/null || true

echo ""
echo -e "${GREEN}  ✓ Setup complete!${NC}"
echo ""
[[ "$PROFILE" == "ckb-node" || "$PROFILE" == "solo-miner" ]] && \
    echo -e "  Dashboard:  ${CYAN}http://$(hostname -I | awk '{print $1}'):8080${NC}"
[[ "$PROFILE" == "fiber-kiosk" ]] && \
    echo -e "  Fiber UI:   ${CYAN}http://$(hostname -I | awk '{print $1}'):9090${NC}"
echo ""
echo -e "  CKB is now syncing. This takes time — check the dashboard for progress."
echo ""
