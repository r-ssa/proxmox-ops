#!/usr/bin/env bash
set -euo pipefail

# power_vm.sh — Phase 7. Start or stop an existing VM/CT.
#
# Uses its own token (~/.config/proxmox-ops/power-token.env), scoped
# to VM.PowerMgmt ONLY — no VM.Audit, no VM.Snapshot, narrower even
# than the MCP server's token. That means this script cannot look up
# a guest by name itself (listing/resolving needs VM.Audit) — the
# caller must already know node/vmid/type, which `fleet` resolves via
# the local inventory.json (built by a token that does have audit
# rights) before calling this. Keeping the actual power-control
# credential unable to enumerate anything is the point, not an
# oversight.
#
# No confirmation prompt, unlike create_vm.sh/delete_vm.sh — start and
# stop are both reversible (a stopped VM can always be started again),
# which is the deliberate line BUILD_PLAN Phase 7 draws between this
# script and the two that are gated.

CONFIG_FILE="${HOME}/.config/proxmox-ops/power-token.env"

die() { echo "power_vm: $*" >&2; exit 1; }

usage() {
  cat >&2 <<'EOF'
Usage: power_vm.sh <start|stop> <vmid> <node> <qemu|lxc>

Low-level — expects the caller (fleet start/stop) to have already
resolved the guest via inventory.json. No confirmation — both actions
are reversible.
EOF
  exit 2
}

[[ $# -ge 4 ]] || usage
ACTION="$1"
VMID="$2"
NODE="$3"
GTYPE="$4"
case "${ACTION}" in
  start|stop) ;;
  *) die "action must be 'start' or 'stop', got '${ACTION}'" ;;
esac
case "${GTYPE}" in
  qemu|lxc) ;;
  *) die "type must be 'qemu' or 'lxc', got '${GTYPE}'" ;;
esac

[[ -f "${CONFIG_FILE}" ]] || die "missing ${CONFIG_FILE}"
# shellcheck disable=SC1090
source "${CONFIG_FILE}"
for required in PVE_HOST PVE_NODE PVE_TOKEN_ID PVE_TOKEN_SECRET; do
  [[ -n "${!required:-}" ]] || die "${CONFIG_FILE} missing ${required}"
done

API="https://${PVE_HOST}:${PVE_PORT:-8006}/api2/json"
CURL_OPTS=(-sS --max-time 20 -H "Authorization: PVEAPIToken=${PVE_TOKEN_ID}=${PVE_TOKEN_SECRET}")
[[ "${PVE_VERIFY_SSL:-false}" == "true" ]] || CURL_OPTS+=(-k)
api() { curl "${CURL_OPTS[@]}" "$@"; }

TASK="$(api -X POST "${API}/nodes/${NODE}/${GTYPE}/${VMID}/status/${ACTION}")"
UPID="$(echo "${TASK}" | jq -r '.data // empty')"
[[ -n "${UPID}" ]] || die "API call failed: $(echo "${TASK}" | jq -r '.errors // .message // .' 2>/dev/null || echo "${TASK}")"

# The POST accepting the request just means Proxmox queued a task —
# it does not mean the task succeeded. Poll the task itself (not just
# guest status) so a failure like "VM is locked" is caught and
# reported here, not silently swallowed as if it worked.
for _ in $(seq 1 15); do
  sleep 1
  TASK_STATUS="$(api "${API}/nodes/${NODE}/tasks/${UPID}/status")"
  STATE="$(echo "${TASK_STATUS}" | jq -r '.data.status // "unknown"')"
  [[ "${STATE}" == "stopped" ]] && break
done

EXIT_STATUS="$(echo "${TASK_STATUS}" | jq -r '.data.exitstatus // "unknown"')"
[[ "${STATE}" == "stopped" ]] || die "task did not finish within 15s (last state: ${STATE}) — check 'qm status ${VMID}' or the Proxmox task log"
[[ "${EXIT_STATUS}" == "OK" ]] || die "task failed: ${EXIT_STATUS}"

echo "power_vm: ${ACTION} completed for vmid ${VMID} on node ${NODE}"
