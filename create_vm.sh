#!/usr/bin/env bash
set -euo pipefail

# create_vm.sh — Phase 3. Clone a VM from the configured cloud-init
# template, inject the CURRENT fleet SSH key, and start it.
#
# Safety model:
#   1. Dry-run is the DEFAULT, same as delete_vm.sh. Real creation
#      requires --yes.
#   2. The chosen vmid is checked for collision before anything is
#      created — never silently reuse or clobber.
#   3. The fleet key is injected explicitly at clone time rather than
#      inherited from whatever is baked into the template. The template
#      currently carries an older key; relying on it would mean rotating
#      the fleet key silently breaks every future clone. Injecting here
#      keeps the template a stable base.
#
# Creation is reversible (delete_vm.sh), so this is deliberately less
# locked-down than delete — but it still never acts without --yes.

CONFIG_FILE="${HOME}/.config/proxmox-ops/token.env"

die() { echo "create_vm: $*" >&2; exit 1; }

usage() {
  cat >&2 <<'EOF'
Usage: create_vm.sh <name> [--vmid N] [--cores N] [--memory MB] [--yes]

  <name>       Name for the new VM.
  --vmid N     Specific vmid. Default: lowest free id >= 200.
  --cores N    Override DEFAULT_CORES from config.
  --memory MB  Override DEFAULT_MEMORY_MB from config.
  --yes        Actually create. Without it, dry-run only.
EOF
  exit 2
}

[[ $# -ge 1 ]] || usage
NAME="$1"; shift || true

VMID=""
CORES=""
MEMORY=""
APPLY=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --vmid) VMID="${2:?--vmid needs a value}"; shift ;;
    --cores) CORES="${2:?--cores needs a value}"; shift ;;
    --memory) MEMORY="${2:?--memory needs a value}"; shift ;;
    --yes) APPLY=true ;;
    -h|--help) usage ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

[[ "${NAME}" =~ ^[a-zA-Z0-9][a-zA-Z0-9-]*$ ]] \
  || die "name must be alphanumeric/hyphens (Proxmox requirement), got: ${NAME}"

[[ -f "${CONFIG_FILE}" ]] || die "missing ${CONFIG_FILE} — run setup.sh first"
# shellcheck disable=SC1090
source "${CONFIG_FILE}"

for required in PVE_HOST PVE_NODE PVE_TOKEN_ID PVE_TOKEN_SECRET DEFAULT_TEMPLATE_VMID; do
  [[ -n "${!required:-}" ]] || die "${CONFIG_FILE} missing ${required}"
done

command -v jq >/dev/null || die "jq not installed"

CORES="${CORES:-${DEFAULT_CORES:-2}}"
MEMORY="${MEMORY:-${DEFAULT_MEMORY_MB:-2048}}"
TEMPLATE="${DEFAULT_TEMPLATE_VMID}"
FLEET_KEY_PUB="${FLEET_SSH_KEY:-${HOME}/.ssh/ai_fleet_ed25519}.pub"

[[ -f "${FLEET_KEY_PUB}" ]] || die "fleet public key not found at ${FLEET_KEY_PUB}"

API="https://${PVE_HOST}:${PVE_PORT:-8006}/api2/json"
CURL_OPTS=(-sS --max-time 30 -H "Authorization: PVEAPIToken=${PVE_TOKEN_ID}=${PVE_TOKEN_SECRET}")
[[ "${PVE_VERIFY_SSL:-false}" == "true" ]] || CURL_OPTS+=(-k)
api() { curl "${CURL_OPTS[@]}" "$@"; }

resources="$(api "${API}/cluster/resources?type=vm")" || die "API unreachable"
mapfile -t USED < <(jq -r '.data[].vmid' <<<"${resources}" | sort -n)

# --- Rail 2: vmid collision check -------------------------------------
if [[ -n "${VMID}" ]]; then
  [[ "${VMID}" =~ ^[0-9]+$ ]] || die "--vmid must be numeric"
  for u in "${USED[@]}"; do
    [[ "${u}" == "${VMID}" ]] && die "vmid ${VMID} is already in use — refusing to clobber"
  done
else
  candidate=200
  while :; do
    collision=false
    for u in "${USED[@]}"; do
      [[ "${u}" == "${candidate}" ]] && { collision=true; break; }
    done
    [[ "${collision}" == false ]] && break
    ((candidate++))
  done
  VMID="${candidate}"
fi

# Confirm the template really is a template before cloning from it.
tmpl="$(jq -c --arg id "${TEMPLATE}" '.data[] | select((.vmid|tostring)==$id)' <<<"${resources}")"
[[ -n "${tmpl}" ]] || die "template vmid ${TEMPLATE} not found on this cluster"
[[ "$(jq -r '.template // 0' <<<"${tmpl}")" == "1" ]] \
  || die "vmid ${TEMPLATE} exists but is NOT a template — refusing to clone from it"
TMPL_NAME="$(jq -r '.name' <<<"${tmpl}")"
TMPL_NODE="$(jq -r '.node' <<<"${tmpl}")"

cat <<EOF

  new vmid:   ${VMID}
  name:       ${NAME}
  from:       ${TEMPLATE} (${TMPL_NAME})
  node:       ${TMPL_NODE}
  cores:      ${CORES}
  memory:     ${MEMORY} MB
  ssh key:    ${FLEET_KEY_PUB}
  ssh user:   ${FLEET_SSH_USER:-ai-agent}

EOF

if [[ "${APPLY}" != "true" ]]; then
  echo "DRY RUN — nothing has been created."
  echo "Re-run with --yes to create it for real."
  exit 0
fi

echo "Cloning ${TEMPLATE} -> ${VMID} (${NAME})..."
clone_resp="$(api -X POST \
  --data-urlencode "newid=${VMID}" \
  --data-urlencode "name=${NAME}" \
  --data-urlencode "full=1" \
  "${API}/nodes/${TMPL_NODE}/qemu/${TEMPLATE}/clone")" || die "clone request failed"

task="$(jq -r '.data // empty' <<<"${clone_resp}")"
[[ -n "${task}" ]] || die "unexpected clone response: ${clone_resp}"
echo "Clone task: ${task}"

for _ in $(seq 1 120); do
  sleep 2
  st="$(api "${API}/nodes/${TMPL_NODE}/tasks/${task}/status" | jq -r '.data.status // "unknown"')"
  if [[ "${st}" == "stopped" ]]; then
    ex="$(api "${API}/nodes/${TMPL_NODE}/tasks/${task}/status" | jq -r '.data.exitstatus // "unknown"')"
    [[ "${ex}" == "OK" ]] || die "clone failed: ${ex}"
    break
  fi
done
[[ "${st:-}" == "stopped" ]] || die "clone did not finish in time — check the Proxmox task log"
echo "Cloned."

echo "Configuring (cores/memory/ssh key)..."
# sshkeys must be URL-encoded by the caller: Proxmox stores the field
# encoded and validates that the value it receives, once decoded off the
# wire, is itself a valid urlencoded string. Passing the raw key gets
# rejected with "invalid urlencoded string". Found by testing, not docs.
SSHKEYS_ENC="$(python3 -c "import urllib.parse,sys; print(urllib.parse.quote(open(sys.argv[1]).read().strip(), safe=''))" "${FLEET_KEY_PUB}")"

config_resp="$(api -X PUT \
  --data-urlencode "cores=${CORES}" \
  --data-urlencode "memory=${MEMORY}" \
  --data-urlencode "ciuser=${FLEET_SSH_USER:-ai-agent}" \
  --data-urlencode "sshkeys=${SSHKEYS_ENC}" \
  "${API}/nodes/${TMPL_NODE}/qemu/${VMID}/config")"

if jq -e '.errors' <<<"${config_resp}" >/dev/null 2>&1; then
  die "config update failed — VM ${VMID} exists but is not fully configured:
${config_resp}"
fi

# The cloud-init drive is generated during the clone, from the
# TEMPLATE's config — which carries whatever key was baked in when the
# template was made. Setting sshkeys afterwards updates the VM config
# but does NOT rebuild that drive, so the guest boots trusting the old
# key. Cloud-init applies ssh keys once per instance, so a later reboot
# does not correct it either. Regenerating here, before first boot, is
# what actually makes the injected key take effect.
echo "Regenerating cloud-init drive so the injected key takes effect..."
api -X PUT "${API}/nodes/${TMPL_NODE}/qemu/${VMID}/cloudinit" >/dev/null \
  || die "cloud-init regeneration failed — VM ${VMID} exists but would boot with the template's key"

echo "Starting..."
api -X POST "${API}/nodes/${TMPL_NODE}/qemu/${VMID}/status/start" >/dev/null \
  || die "start failed — VM ${VMID} exists but did not boot"

echo
echo "Created and started vmid ${VMID} (${NAME})."
echo "Run fleet-inventory.sh once it has booted to pick up its IP and add it to ~/.ssh/config.d/fleet."
