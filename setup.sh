#!/usr/bin/env bash
set -euo pipefail

# Creates the proxmox-ops credential file. Deliberately separate from
# proxmox-monitor's token: this one grows mutating scope in later phases
# (see BUILD_PLAN.md), and that growth must never apply to the read-only
# token the monitor repo uses.

CONFIG_DIR="${HOME}/.config/proxmox-ops"
CONFIG_FILE="${CONFIG_DIR}/token.env"
FLEET_KEY="${HOME}/.ssh/ai_fleet_ed25519"

if [[ -f "${CONFIG_FILE}" ]]; then
  echo "Config already exists at ${CONFIG_FILE} — leaving it alone."
  echo "Delete it first if you want to redo setup."
  exit 0
fi

echo "This creates ${CONFIG_FILE} (mode 600), never committed to git."
echo
echo "Phase 1 needs read-only scope only (PVEAuditor is the built-in role"
echo "that covers it). Later phases widen it — see BUILD_PLAN.md. Do NOT"
echo "reuse proxmox-monitor's token here."
echo

read -rp "Proxmox host/IP: " host
read -rp "Proxmox port [8006]: " port
port="${port:-8006}"
read -rp "Node name (e.g. pve): " node
read -rp "API token ID (e.g. root@pam!ops-fleet): " token_id
read -rsp "API token secret: " token_secret
echo

mkdir -p "${CONFIG_DIR}"
umask 177
cat > "${CONFIG_FILE}" <<EOF
PVE_HOST=${host}
PVE_PORT=${port}
PVE_NODE=${node}
PVE_TOKEN_ID=${token_id}
PVE_TOKEN_SECRET=${token_secret}
PVE_VERIFY_SSL=false
FLEET_SSH_KEY=${FLEET_KEY}
FLEET_SSH_USER=ai-agent
EOF
chmod 600 "${CONFIG_FILE}"
echo "Wrote ${CONFIG_FILE}"

if [[ ! -f "${FLEET_KEY}" ]]; then
  echo
  echo "NOTE: fleet SSH key not found at ${FLEET_KEY}."
  echo "Generate one with:"
  echo "  ssh-keygen -t ed25519 -f ${FLEET_KEY} -N '' -C proxmox-ops-fleet-access"
fi
