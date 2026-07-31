# BUILD_PLAN.md

Work through these phases in order. Each has a goal and an explicit STOP.
Do not proceed past a STOP until it's resolved by testing successfully or
by getting an answer from the user. Do not combine phases even if it looks
easy to.

This plan only covers this repo's job (VM/CT lifecycle + agent fleet
access). Rice, monitoring, backups, and model-serving are out of scope —
see [rafael-systems](https://github.com/r-ssa/rafael-systems).

---

## PHASE 0 — Confirm before starting

STOP: confirm both with the user before Phase 1.

1. **Secrets**: a bootstrap-generated, gitignored local config file,
   created interactively, never committed — same approach that worked
   for the old repo. Token must never be committed under any
   circumstance.
2. **Test target**: what VM/CT/resource pool on the real cluster is
   safe to treat as disposable during development, so create/delete
   logic is tested against something real without risking anything
   that matters. Get this named explicitly, don't assume "anything not
   obviously important" is fair game.

---

## PHASE 1 — Fleet discovery + SSH access layer

Goal: enumerate existing VMs/CTs and make them reachable, read-only.
This is the foundation everything else builds on.

Steps:
- Scoped API token, read-only for this phase (`VM.Audit` + `Sys.Audit`
  — confirm these still exist under the Proxmox VE version actually
  running; the old repo found `VM.Monitor` had been removed as of
  PVE 9.x, don't assume the plan's permission names are still current,
  verify against the live API).
- `fleet-inventory.sh`: enumerate VMs/CTs via the API, resolve IPs
  (guest agent first, ARP fallback), regenerate an SSH config so
  `ssh <name>` reaches any of them, output JSON inventory.
- Dedicated fleet SSH key, separate from the user's personal keys and
  separate from any GitHub-auth key — this key's only job is reaching
  fleet guests.

STOP: run discovery against the test target from Phase 0, confirm it
resolves correctly and the generated SSH config actually connects,
before writing anything that mutates.

---

## PHASE 2 — VM template prerequisite

Goal: confirm a cloud-init template with SSH keys pre-baked exists
before clone logic is written — cloning nothing is not a phase.

STOP: ask the user whether this template already exists. If not,
building it is a prerequisite task, scoped and confirmed separately
before Phase 3 starts.

---

## PHASE 3 — Create VM/CT

Goal: clone-from-template, safely.

Steps:
- Expand the token's scope only as far as this phase needs. Starting
  point, informed by what the old repo found was actually required by
  testing (not by guessing generously): `VM.Allocate`, `VM.Clone`,
  `Datastore.AllocateSpace`, `SDN.Use` (if the cluster registers a
  bridge as an SDN zone), `VM.Config.CPU`/`Memory`/`Options`. Verify
  each permission is actually exercised — don't carry forward ones
  that turn out unnecessary on this cluster.
- `create_vm.sh`: name prompt, sane resource defaults (confirm the
  actual numbers with the user, don't invent them), **explicit
  confirmation step before the clone runs for real** — no path from
  "asked for a VM" to "VM exists" without a human confirming in
  between.

STOP: test create against the Phase 0 test target. Confirm there is no
path that skips the confirmation step.

---

## PHASE 4 — Delete + list

Goal: symmetric to Phase 3 — nothing created in testing should be
permanently orphaned.

Steps:
- Expand scope: `VM.PowerMgmt` (stop before delete), delete/destroy
  permission itself, scoped as narrowly as the API allows.
- `delete_vm.sh`: list view, explicit confirmation, same standard as
  create — no single click from "list" to "gone."

STOP: test delete against something created in Phase 3's testing.
Confirm, explicitly, that there is no single-click no-confirmation path
to delete — re-check this even though Phase 3 already established the
pattern, since delete is the one mistake here that isn't reversible.

---

## PHASE 5 — Unified fleet CLI

Goal: one CLI (`fleet`) wrapping discovery, SSH, create, delete, so
agents and the user have one consistent interface instead of separate
scripts.

Steps:
- `fleet list` / `fleet ssh <name> [cmd]` / `fleet exec-all <cmd>` /
  `fleet host [cmd]` / `fleet create-vm ...` / `fleet refresh`.
- New VMs created through this CLI get the fleet key injected and
  inventory refreshed automatically — no manual per-VM setup step
  afterward, that was the whole point of building this.

STOP: none required, this phase only wraps what Phases 1–4 already
proved works. Still gets a PR, still gets read before merge.

---

## PHASE 6 — Agent access (MCP server)

Goal: let Claude Code and other agents reach the fleet through the CLI
built in Phase 5, not through raw credentials.

Steps:
- MCP server exposing list/status/start/stop/snapshot.
- **Delete/destroy is explicitly not exposed through the MCP server.**
  That capability only exists through `fleet`'s own confirm-gated path,
  run by a human. This was a deliberate old-repo decision worth
  keeping, not an oversight to "fix" by adding it later.

STOP: write out the explicit tool list the MCP server will expose and
confirm it with the user before wiring it into any agent config. Do
not expose more than what's confirmed here.

---

## Notes for whoever (human or agent) picks up a phase

- Every phase's STOP is a real stop, not a formality — the ACL list
  above is a starting point informed by prior experience, not a
  guarantee for this cluster's current Proxmox version. Verify by
  testing, the way the original build did.
- This repo is public (see `rafael-systems` for why) and branch-
  protected — work happens on a branch, opened as a PR, merged by the
  user after reading the diff.
