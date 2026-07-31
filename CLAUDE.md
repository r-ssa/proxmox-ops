# CLAUDE.md

## Job
Create/delete/configure VMs and CTs on demand; give AI agents access to the fleet.

## Non-goals
- Doesn't do read-only monitoring or display — that's `proxmox-monitor`'s job. Don't duplicate stat-fetching here even if it's convenient mid-task.
- Doesn't manage the desktop (`rice`) or serve models (`ai-serve`).

## Before adding anything
Check it against the Job and Non-goals above. If it doesn't cleanly fit, stop and ask — don't force it in. Full repo map and dependency direction: https://github.com/r-ssa/rafael-systems

## This is the highest-risk repo in the constellation. Extra rules:
- It holds the mutating Proxmox API token and the fleet SSH identity. Never widen a token's scope beyond what a specific, currently-needed capability requires — the old repo's ACL list was built by testing each permission was actually necessary, not by guessing generously upfront. Keep doing that.
- Any new mutating capability (a new script, a new API call that creates/deletes/changes something) gets proposed as a phase in `BUILD_PLAN.md` with an explicit STOP before it's implemented. Do not implement a mutating capability in the same turn it's requested — write the plan, wait for the user to confirm, then build.
- `main` should be branch-protected, but GitHub Pro is required for that on a private repo — not yet active. Until it is, treat this as an honor rule: work on a branch + PR for the user to read, never push directly to `main`, even though nothing currently blocks it.
- Before touching anything that talks to the real Proxmox cluster, prefer testing against the throwaway VM/resource pool the user has scoped for this, not production VMs, unless the user explicitly says otherwise for that specific action.
