#!/bin/bash
# Profile: solo-miner
# CKB full node + stratum proxy in solo mode (no dashboard DE, minimal)

# Inherit everything from ckb-node, then tweak stratum config for solo
source "${OVERLAY}/profiles/ckb-node.sh"

_ckb_node_main() { profile_main; }  # save reference

profile_main() {
    _ckb_node_main

    echo ">>> [solo-miner] Configuring stratum proxy for solo mode"

    # Mark as solo in the stratum config template
    # firstboot wizard will fill in reward address
    cat > /etc/stratum/config.json.template << 'TMPL'
{
  "mode": "solo",
  "ckb_rpc": "http://localhost:8114",
  "stratum_port": 3333,
  "stats_port": 8081,
  "reward_address": "__REWARD_ADDRESS__"
}
TMPL

    # Updated motd
    cat >> /etc/motd << 'MOTD'

  ╔════════════════════════════════════════════╗
  ║   CKB Solo Miner — Wyltek Industries       ║
  ║   Stratum:   stratum+tcp://<ip>:3333       ║
  ║   Stats:     http://<ip>:8081              ║
  ║   Dashboard: http://<ip>:8080              ║
  ╚════════════════════════════════════════════╝

MOTD

    echo ">>> [solo-miner] done"
}
