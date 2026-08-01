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

## PHASE 7 — Human-facing start/stop CLI

Goal: let `proxmox-monitor`'s dashboard (and direct terminal use) start
and stop existing VMs/CTs, without going through the MCP-only agent
path and without that dashboard ever holding a mutating credential of
its own.

Context: Phase 6 already proved `fleet_start`/`fleet_stop` work safely
for agents, on a token scoped to `VM.PowerMgmt` + `VM.Snapshot` only —
no `VM.Allocate`/`VM.Clone`, so it can't create or destroy anything.
There's currently no equivalent for a human outside that MCP path;
`fleet` itself only exposes `list`/`ssh`/`exec-all`/`host`/`create-vm`/
`delete-vm`/`refresh`.

Steps:
- New scoped API token, `VM.PowerMgmt` only (narrower than the MCP
  token — this path never needs `VM.Snapshot`). Verify the permission
  name against the live API before assuming it's still called that.
- `fleet start <name|vmid>` / `fleet stop <name|vmid>`: resolve via
  the existing inventory, POST `status/start` or `status/stop`, poll
  for the state to actually change, print the result. No confirmation
  prompt — start/stop are both reversible (a stopped VM can always be
  started again), matching the MCP server's own no-confirmation
  precedent for these two actions specifically. This is a deliberate
  difference from create/delete, not an inconsistency.
- **Create and delete stay out of `proxmox-monitor`'s dashboard
  entirely.** This mirrors Phase 6's own rule for the MCP server —
  anything irreversible only ever happens through `fleet`'s existing
  confirm-gated CLI path, run by a human in a terminal, never from a
  live-refreshing dashboard where a keystroke could be mistimed.
- Dashboard side (in `proxmox-monitor`, a separate repo, tracked
  there): an inline start/stop control per VM row, with real mouse
  click support in the TUI (kitty SGR mouse reporting) rather than a
  keyboard-only selection scheme — tested in isolation before it's
  wired to a real start/stop call.

STOP: test `fleet start`/`fleet stop` against the existing disposable
test VM (`phase3-throwaway`, vmid 200) before wiring anything into the
dashboard. Confirm mouse-click parsing works correctly in isolation
(a throwaway test harness, not the real dashboard) before connecting
it to a call that actually starts or stops a real guest.

---

## PHASE 8 — Dashboard-triggered VM creation (create only, not delete)

Goal: let the dashboard create a new VM via `create_vm.sh`'s existing
`--yes`-gated path. Explicitly does NOT add delete to the dashboard —
that stays CLI-only, unchanged from every prior phase. The user's own
reasoning: creation is already less locked-down than delete
(`create_vm.sh`'s own comment: "reversible... deliberately less
locked-down than delete"), so the same asymmetry that already exists
between `create_vm.sh` and `delete_vm.sh` carries into the dashboard.

Context: the dashboard's input model is single-keystroke only (`b`,
row-clicks) — no text-entry field exists, and building one is out of
scope for this phase. Naming needs to work without it.

Steps:
- No new credential. `fleet create-vm` already exists and already
  uses the full `ops-fleet` token (`VM.Allocate`/`VM.Clone`/etc) —
  the dashboard still never holds that token itself, it just shells
  out to `fleet create-vm`, same delegation pattern as backups and
  Phase 7's power control.
- Naming: the dashboard computes the next free vmid itself (lowest
  integer >= 200 not already in the current guest list — the same
  guest list it already has from `proxmox_monitor.py`, no extra API
  call needed) and names the VM after that vmid (e.g. `201`), passing
  both `--vmid` and the name explicitly so they can't drift apart.
  `create_vm.sh`'s own collision check is the safety net if two
  things race for the same id — not re-implemented here.
- UX: press `c` to show a preview (vmid/name, cores, memory — from
  the same config `create_vm.sh` already reads defaults from), press
  `y` to confirm, any other key cancels. All single-keystroke,
  consistent with the rest of the dashboard. Output streamed live,
  same pattern as the manual backup trigger.
- Delete stays entirely unreachable from the dashboard — not a
  placeholder to fill in later, a deliberate line matching Phase 6's
  own MCP rule and Phase 7's own reasoning.

STOP: confirm the vmid/name preview renders correctly and the
computed next-free-vmid is actually correct against live inventory
before wiring the `y` confirm to a real `create_vm.sh --yes` call.

---

## Notes for whoever (human or agent) picks up a phase

- Every phase's STOP is a real stop, not a formality — the ACL list
  above is a starting point informed by prior experience, not a
  guarantee for this cluster's current Proxmox version. Verify by
  testing, the way the original build did.
- This repo is public (see `rafael-systems` for why) and branch-
  protected — work happens on a branch, opened as a PR, merged by the
  user after reading the diff.
