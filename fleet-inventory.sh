#!/usr/bin/env bash
set -euo pipefail

# fleet-inventory.sh — Phase 1. Enumerate every VM/CT on the cluster,
# resolve each one's IP, and write both a JSON inventory and an SSH
# config fragment so `ssh vm-<name>` reaches any of them.
#
# READ-ONLY. This script never creates, deletes, starts, stops, or
# reconfigures anything. It only reads the API and writes two local
# files. Mutating capabilities are Phase 3+ and live in other scripts.
#
# IP resolution, in order:
#   1. QEMU guest agent via the API — most reliable, needs the agent
#      installed and running in the guest.
#   2. MAC from the guest's config (API) matched against the LOCAL ARP
#      table on this machine.
#
# Deliberate design note on (2): the old implementation of this idea
# SSH'd into the Proxmox host as root to run a subnet ping sweep and
# read its ARP table. That made root-on-the-hypervisor a permanent
# dependency of routine inventory refresh, which is far more access
# than this job needs. This machine is on the same L2 segment as the
# guests, so the same resolution works locally with no hypervisor shell
# access at all. If that assumption ever breaks (guests moved to an
# isolated VLAN), this falls back to "agent-only" rather than silently
# escalating privileges — fix it by installing the guest agent, not by
# reintroducing root SSH.

CONFIG_FILE="${HOME}/.config/proxmox-ops/token.env"
INVENTORY_JSON="${HOME}/.config/proxmox-ops/inventory.json"
SSH_CONFIG_D="${HOME}/.ssh/config.d"
FLEET_SSH_CONFIG="${SSH_CONFIG_D}/fleet"

die() { echo "fleet-inventory: $*" >&2; exit 1; }

[[ -f "${CONFIG_FILE}" ]] || die "missing ${CONFIG_FILE} — run setup.sh first"
# shellcheck disable=SC1090
source "${CONFIG_FILE}"

for required in PVE_HOST PVE_NODE PVE_TOKEN_ID PVE_TOKEN_SECRET; do
  [[ -n "${!required:-}" ]] || die "${CONFIG_FILE} missing ${required}"
done

command -v jq >/dev/null || die "jq not installed"

API="https://${PVE_HOST}:${PVE_PORT:-8006}/api2/json"
AUTH_HEADER="Authorization: PVEAPIToken=${PVE_TOKEN_ID}=${PVE_TOKEN_SECRET}"
CURL_OPTS=(-sS --max-time 10 -H "${AUTH_HEADER}")
[[ "${PVE_VERIFY_SSL:-false}" == "true" ]] || CURL_OPTS+=(-k)

api_get() {
  curl "${CURL_OPTS[@]}" "${API}$1"
}

# --- Local ARP-based resolution -------------------------------------
# Populate the local neighbour table by sweeping the subnet this
# machine sits on. Backgrounded pings with a short timeout; we don't
# care about replies, only about the ARP entries they provoke.
warm_arp_cache() {
  local subnet
  subnet="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}' \
    | awk -F. '{print $1"."$2"."$3}')"
  [[ -n "${subnet}" ]] || return 0
  local i
  for i in $(seq 1 254); do
    ping -c1 -W1 "${subnet}.${i}" >/dev/null 2>&1 &
  done
  wait
}

ip_from_mac() {
  local mac="$1"
  ip neigh show 2>/dev/null \
    | grep -i "${mac}" \
    | awk '{print $1}' \
    | grep -E '^[0-9]+\.' \
    | head -n1 || true
}

# --- Guest agent resolution -----------------------------------------
ip_from_agent() {
  local node="$1" vmid="$2"
  api_get "/nodes/${node}/qemu/${vmid}/agent/network-get-interfaces" 2>/dev/null \
    | jq -r '.data.result[]?["ip-addresses"][]?
             | select(.["ip-address-type"]=="ipv4")
             | .["ip-address"]' 2>/dev/null \
    | grep -v '^127\.' \
    | head -n1 || true
}

# --- Main ------------------------------------------------------------
resources="$(api_get "/cluster/resources?type=vm")" \
  || die "API unreachable at ${API}"

if ! echo "${resources}" | jq -e '.data' >/dev/null 2>&1; then
  die "unexpected API response (bad token or insufficient permissions?): ${resources}"
fi

echo "fleet-inventory: warming local ARP cache..." >&2
warm_arp_cache

mkdir -p "$(dirname "${INVENTORY_JSON}")" "${SSH_CONFIG_D}"
chmod 700 "${SSH_CONFIG_D}"

ssh_entries=()
json_entries=()
skipped=()

while IFS= read -r guest; do
  [[ -n "${guest}" ]] || continue

  vmid="$(jq -r '.vmid' <<<"${guest}")"
  node="$(jq -r '.node' <<<"${guest}")"
  type="$(jq -r '.type' <<<"${guest}")"
  name="$(jq -r '.name // empty' <<<"${guest}")"
  status="$(jq -r '.status' <<<"${guest}")"
  template="$(jq -r '.template // 0' <<<"${guest}")"

  [[ "${template}" == "1" ]] && continue
  if [[ "${status}" != "running" ]]; then
    skipped+=("${name:-vmid-${vmid}} (${status})")
    continue
  fi

  guest_path="qemu"
  [[ "${type}" == "lxc" ]] && guest_path="lxc"

  ip=""
  [[ "${type}" == "qemu" ]] && ip="$(ip_from_agent "${node}" "${vmid}")"

  if [[ -z "${ip}" ]]; then
    config="$(api_get "/nodes/${node}/${guest_path}/${vmid}/config" 2>/dev/null || true)"
    mac="$(jq -r '.data.net0 // empty' <<<"${config}" 2>/dev/null \
      | grep -oiE '([0-9a-f]{2}:){5}[0-9a-f]{2}' | head -n1 || true)"
    [[ -n "${mac}" ]] && ip="$(ip_from_mac "${mac}")"
  fi

  if [[ -z "${ip}" ]]; then
    skipped+=("${name:-vmid-${vmid}} (running, no IP resolved)")
    continue
  fi

  slug="$(tr '[:upper:]' '[:lower:]' <<<"${name:-vmid-${vmid}}" \
    | tr -c 'a-z0-9\n' '-' | sed 's/-\+/-/g; s/^-//; s/-$//')"
  alias="vm-${slug}"

  ssh_entries+=("Host ${alias}
  HostName ${ip}
  User ${FLEET_SSH_USER:-ai-agent}
  IdentityFile ${FLEET_SSH_KEY:-${HOME}/.ssh/ai_fleet_ed25519}
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
")

  json_entries+=("$(jq -n \
    --arg name "${name}" --arg alias "${alias}" --arg ip "${ip}" \
    --arg vmid "${vmid}" --arg type "${type}" --arg node "${node}" \
    '{name:$name, alias:$alias, ip:$ip, vmid:$vmid, type:$type, node:$node}')")
done < <(echo "${resources}" | jq -c '.data[] | select(.type=="qemu" or .type=="lxc")')

{
  echo "# AUTO-GENERATED by proxmox-ops/fleet-inventory.sh — do not edit."
  echo "# Regenerated: $(date -Iseconds)"
  echo
  printf '%s\n' "${ssh_entries[@]:-}"
} > "${FLEET_SSH_CONFIG}"
chmod 600 "${FLEET_SSH_CONFIG}"

printf '%s\n' "${json_entries[@]:-}" | jq -s '.' > "${INVENTORY_JSON}"
chmod 600 "${INVENTORY_JSON}"

echo "fleet-inventory: wrote ${#ssh_entries[@]} reachable host(s) to ${FLEET_SSH_CONFIG}"
if [[ "${#skipped[@]}" -gt 0 ]]; then
  echo "fleet-inventory: skipped ${#skipped[@]}:" >&2
  printf '  - %s\n' "${skipped[@]}" >&2
fi

# ~/.ssh/config must pull in the fragment for `ssh vm-<name>` to work.
if [[ -f "${HOME}/.ssh/config" ]] && ! grep -qE '^\s*Include\s+config\.d/\*' "${HOME}/.ssh/config"; then
  echo >&2
  echo "NOTE: ~/.ssh/config does not Include config.d/*. Add this as its FIRST line:" >&2
  echo "  Include config.d/*" >&2
elif [[ ! -f "${HOME}/.ssh/config" ]]; then
  echo "Include config.d/*" > "${HOME}/.ssh/config"
  chmod 600 "${HOME}/.ssh/config"
  echo "fleet-inventory: created ~/.ssh/config with Include config.d/*" >&2
fi
