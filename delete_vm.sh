#!/usr/bin/env bash
set -euo pipefail

# delete_vm.sh — Phase 4. Destroy a VM/CT, with the safety rails the
# BUILD_PLAN requires for the one operation here that cannot be undone.
#
# Safety model, in order of enforcement:
#   1. PROTECTED_VMIDS in the config file are refused outright. No flag,
#      no prompt, no override path in this script. To delete one of
#      those you must first remove it from the config by hand — a
#      deliberate, separate act.
#   2. Templates are refused. Losing a template silently breaks every
#      future clone.
#   3. Dry-run is the DEFAULT. It shows exactly what would happen and
#      exits without touching anything. Real deletion requires --yes.
#   4. Even with --yes, the operator must type the VM's name exactly.
#      Typing a vmid is too easy to get wrong by one digit; a name is
#      not.
#   5. A running VM is stopped first, and that stop is itself reported
#      before the destroy proceeds.
#
# There is deliberately no "--force" that skips 3 and 4 together. If
# that ever seems necessary, the right fix is a different tool, not a
# bigger hammer in this one.

CONFIG_FILE="${HOME}/.config/proxmox-ops/token.env"

die() { echo "delete_vm: $*" >&2; exit 1; }

usage() {
  cat >&2 <<'EOF'
Usage: delete_vm.sh <vmid> [--yes]

  <vmid>   The VM/CT to destroy.
  --yes    Actually perform the deletion. Without this, runs as a
           dry-run and changes nothing.

Dry-run is the default on purpose. Run it first, read what it says.
EOF
  exit 2
}

[[ $# -ge 1 ]] || usage
VMID="$1"
shift || true

APPLY=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes) APPLY=true ;;
    -h|--help) usage ;;
    *) die "unknown argument: $1" ;;
  esac
  shift
done

[[ "${VMID}" =~ ^[0-9]+$ ]] || die "vmid must be numeric, got: ${VMID}"
[[ -f "${CONFIG_FILE}" ]] || die "missing ${CONFIG_FILE} — run setup.sh first"
# shellcheck disable=SC1090
source "${CONFIG_FILE}"

for required in PVE_HOST PVE_NODE PVE_TOKEN_ID PVE_TOKEN_SECRET; do
  [[ -n "${!required:-}" ]] || die "${CONFIG_FILE} missing ${required}"
done

command -v jq >/dev/null || die "jq not installed"

API="https://${PVE_HOST}:${PVE_PORT:-8006}/api2/json"
CURL_OPTS=(-sS --max-time 20 -H "Authorization: PVEAPIToken=${PVE_TOKEN_ID}=${PVE_TOKEN_SECRET}")
[[ "${PVE_VERIFY_SSL:-false}" == "true" ]] || CURL_OPTS+=(-k)

api() { curl "${CURL_OPTS[@]}" "$@"; }

# --- Rail 1: protected list ------------------------------------------
IFS=',' read -ra PROTECTED <<< "${PROTECTED_VMIDS:-}"
for p in "${PROTECTED[@]}"; do
  if [[ "${p// /}" == "${VMID}" ]]; then
    die "vmid ${VMID} is in PROTECTED_VMIDS — refusing.
To delete it, remove it from PROTECTED_VMIDS in ${CONFIG_FILE} first.
That is deliberately a separate, manual act."
  fi
done

# --- Locate the guest -------------------------------------------------
resources="$(api "${API}/cluster/resources?type=vm")" || die "API unreachable"
guest="$(jq -c --arg id "${VMID}" '.data[] | select((.vmid|tostring) == $id)' <<<"${resources}")"
[[ -n "${guest}" ]] || die "no VM/CT with vmid ${VMID} found on this cluster"

NAME="$(jq -r '.name // "(unnamed)"' <<<"${guest}")"
NODE="$(jq -r '.node' <<<"${guest}")"
TYPE="$(jq -r '.type' <<<"${guest}")"
STATUS="$(jq -r '.status' <<<"${guest}")"
TEMPLATE="$(jq -r '.template // 0' <<<"${guest}")"
MAXDISK_GB="$(jq -r '(.maxdisk // 0) / 1024 / 1024 / 1024 | floor' <<<"${guest}")"

GUEST_PATH="qemu"
[[ "${TYPE}" == "lxc" ]] && GUEST_PATH="lxc"

# --- Rail 2: never destroy a template ---------------------------------
if [[ "${TEMPLATE}" == "1" ]]; then
  die "vmid ${VMID} (${NAME}) is a TEMPLATE — refusing.
Destroying a template silently breaks every future clone that depends
on it. Delete it from the Proxmox UI if you genuinely mean to."
fi

cat <<EOF

  vmid:     ${VMID}
  name:     ${NAME}
  type:     ${TYPE}
  node:     ${NODE}
  status:   ${STATUS}
  disk:     ~${MAXDISK_GB}GB (will be freed and is NOT recoverable)

EOF

# --- Rail 3: dry-run default ------------------------------------------
if [[ "${APPLY}" != "true" ]]; then
  echo "DRY RUN — nothing has been changed."
  [[ "${STATUS}" == "running" ]] && echo "Would stop the VM first (it is currently running)."
  echo "Would permanently destroy vmid ${VMID} (${NAME}) and its ~${MAXDISK_GB}GB disk."
  echo
  echo "Re-run with --yes to do it for real."
  exit 0
fi

# --- Rail 4: type the name --------------------------------------------
echo "This is PERMANENT. The disk cannot be recovered afterwards."
read -rp "Type the VM's name exactly (${NAME}) to confirm: " typed
if [[ "${typed}" != "${NAME}" ]]; then
  die "name did not match (got '${typed}', expected '${NAME}') — aborted, nothing changed"
fi

# --- Rail 5: stop if running ------------------------------------------
if [[ "${STATUS}" == "running" ]]; then
  echo "Stopping ${NAME}..."
  api -X POST "${API}/nodes/${NODE}/${GUEST_PATH}/${VMID}/status/stop" >/dev/null \
    || die "failed to stop — aborted before destroy, nothing deleted"
  for _ in $(seq 1 30); do
    sleep 2
    cur="$(api "${API}/nodes/${NODE}/${GUEST_PATH}/${VMID}/status/current" | jq -r '.data.status // "unknown"')"
    [[ "${cur}" == "stopped" ]] && break
  done
  [[ "${cur:-}" == "stopped" ]] || die "VM did not reach stopped state — aborted before destroy, nothing deleted"
  echo "Stopped."
fi

echo "Destroying ${NAME} (vmid ${VMID})..."
resp="$(api -X DELETE "${API}/nodes/${NODE}/${GUEST_PATH}/${VMID}")" \
  || die "destroy call failed: ${resp:-no response}"

task="$(jq -r '.data // empty' <<<"${resp}")"
if [[ -z "${task}" ]]; then
  die "unexpected response from destroy: ${resp}"
fi

echo "Destroy task: ${task}"
for _ in $(seq 1 60); do
  sleep 2
  st="$(api "${API}/nodes/${NODE}/tasks/${task}/status" | jq -r '.data.status // "unknown"')"
  if [[ "${st}" == "stopped" ]]; then
    exitstatus="$(api "${API}/nodes/${NODE}/tasks/${task}/status" | jq -r '.data.exitstatus // "unknown"')"
    if [[ "${exitstatus}" == "OK" ]]; then
      echo "Destroyed vmid ${VMID} (${NAME})."
      exit 0
    fi
    die "destroy task finished with: ${exitstatus}"
  fi
done

die "destroy task did not complete within timeout — check the Proxmox UI task log"
