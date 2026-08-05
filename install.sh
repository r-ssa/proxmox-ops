#!/usr/bin/env bash
set -euo pipefail

# install.sh — symlink this repo's CLI entrypoints into ~/.local/bin so
# `fleet` (and its helper scripts) on PATH are always the current repo
# version. Replaces the old habit of manually `cp`-ing files there,
# which silently went stale across Phases 7-8: ~/.local/bin/fleet and
# friends were months-old copies missing start/stop/create-vm, and
# power_vm.sh had never been deployed there at all. A symlink can't go
# stale the same way — it always points at whatever's on disk here.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="${HOME}/.local/bin"

ENTRYPOINTS=(fleet fleet-inventory.sh create_vm.sh delete_vm.sh power_vm.sh)

mkdir -p "${BIN_DIR}"

for name in "${ENTRYPOINTS[@]}"; do
  src="${SCRIPT_DIR}/${name}"
  dest="${BIN_DIR}/${name}"
  [[ -f "${src}" ]] || { echo "install.sh: missing ${src}" >&2; exit 1; }

  if [[ -e "${dest}" && ! -L "${dest}" ]]; then
    echo "install.sh: ${dest} exists and is not a symlink — remove or back it up first, not overwriting" >&2
    exit 1
  fi

  ln -sf "${src}" "${dest}"
  echo "install.sh: linked ${dest} -> ${src}"
done

echo "install.sh: done. Re-run any time after pulling repo changes; nothing to keep in sync manually anymore."
