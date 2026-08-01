#!/usr/bin/env python3
"""proxmox-ops MCP server — Phase 6, agent access to the fleet.

Exposes exactly five tools, confirmed with the user before this file
was written: fleet_list, fleet_status, fleet_start, fleet_stop,
fleet_snapshot. Nothing else.

Deliberately does NOT expose create or delete. That's not just a
code-level choice — the token this server authenticates with
(root@pam!mcp-agent) is scoped to a custom role (VM.Audit +
VM.PowerMgmt + VM.Snapshot only) with no VM.Allocate/VM.Clone or
delete permission at all. Verified live before this file was written:
the token can list/start/stop/snapshot VM 200, and a direct clone
attempt against it was rejected by the API with a permission error.
So even a bug in this file, or a successful prompt injection against
whatever agent is driving it, cannot create or destroy a VM — the
credential itself is the backstop, not just the tool list below.

Uses its own token file (~/.config/proxmox-ops/mcp-token.env),
separate from the fuller ops-fleet token that create_vm.sh/delete_vm.sh
use — this server should never be handed that broader credential.
"""
import json
import os
import ssl
import urllib.error
import urllib.parse
import urllib.request

import mcp.types as types
from mcp.server import Server
from mcp.server.stdio import stdio_server

CONFIG_FILE = os.path.expanduser("~/.config/proxmox-ops/mcp-token.env")


def load_config():
    if not os.path.isfile(CONFIG_FILE):
        raise RuntimeError(f"missing {CONFIG_FILE}")
    cfg = {}
    with open(CONFIG_FILE) as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, _, v = line.partition("=")
            cfg[k.strip()] = v.strip()
    for required in ("PVE_HOST", "PVE_NODE", "PVE_TOKEN_ID", "PVE_TOKEN_SECRET"):
        if required not in cfg:
            raise RuntimeError(f"{CONFIG_FILE} missing {required}")
    return cfg


CFG = load_config()
API = f"https://{CFG['PVE_HOST']}:{CFG.get('PVE_PORT', '8006')}/api2/json"
AUTH = f"PVEAPIToken={CFG['PVE_TOKEN_ID']}={CFG['PVE_TOKEN_SECRET']}"

_ssl_ctx = None
if CFG.get("PVE_VERIFY_SSL", "false").lower() != "true":
    _ssl_ctx = ssl.create_default_context()
    _ssl_ctx.check_hostname = False
    _ssl_ctx.verify_mode = ssl.CERT_NONE


def api_call(method, path, data=None, timeout=20):
    url = f"{API}{path}"
    body = None
    if data is not None:
        body = urllib.parse.urlencode(data).encode()
    req = urllib.request.Request(url, data=body, method=method, headers={"Authorization": AUTH})
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=_ssl_ctx) as resp:
            return json.load(resp).get("data")
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")
        raise RuntimeError(f"HTTP {e.code}: {detail}") from e
    except urllib.error.URLError as e:
        raise RuntimeError(f"unreachable: {e}") from e


def resolve_guest(name_or_vmid):
    """Find a guest by exact name or vmid. Raises if not found or ambiguous."""
    resources = api_call("GET", "/cluster/resources?type=vm") or []
    matches = [
        r for r in resources
        if str(r.get("vmid")) == str(name_or_vmid) or r.get("name") == name_or_vmid
    ]
    if not matches:
        raise RuntimeError(f"no guest matching '{name_or_vmid}'")
    if len(matches) > 1:
        raise RuntimeError(f"'{name_or_vmid}' is ambiguous: matches {[m['vmid'] for m in matches]}")
    return matches[0]


TOOLS = [
    types.Tool(
        name="fleet_list",
        description="List all known VMs/CTs on the fleet: name, vmid, type, status.",
        inputSchema={"type": "object", "properties": {}},
    ),
    types.Tool(
        name="fleet_status",
        description="Detailed status of one guest (cpu, memory, uptime).",
        inputSchema={
            "type": "object",
            "properties": {"guest": {"type": "string", "description": "Name or vmid"}},
            "required": ["guest"],
        },
    ),
    types.Tool(
        name="fleet_start",
        description="Start a stopped VM/CT.",
        inputSchema={
            "type": "object",
            "properties": {"guest": {"type": "string", "description": "Name or vmid"}},
            "required": ["guest"],
        },
    ),
    types.Tool(
        name="fleet_stop",
        description="Stop a running VM/CT. This is disruptive to anything using it — "
        "there is no confirmation step, unlike create/delete elsewhere in this project. "
        "Use with real judgment about whether the guest is in active use.",
        inputSchema={
            "type": "object",
            "properties": {"guest": {"type": "string", "description": "Name or vmid"}},
            "required": ["guest"],
        },
    ),
    types.Tool(
        name="fleet_snapshot",
        description="Create a snapshot of a VM. Additive only — never deletes or "
        "overwrites existing snapshots.",
        inputSchema={
            "type": "object",
            "properties": {
                "guest": {"type": "string", "description": "Name or vmid"},
                "snapshot_name": {"type": "string", "description": "Name for the snapshot"},
            },
            "required": ["guest", "snapshot_name"],
        },
    ),
]


def _result(payload, is_error=False):
    return types.CallToolResult(
        content=[types.TextContent(type="text", text=json.dumps(payload, indent=2))],
        isError=is_error,
    )


async def on_list_tools(ctx, params):
    return types.ListToolsResult(tools=TOOLS)


async def on_call_tool(ctx, params: types.CallToolRequestParams):
    name = params.name
    arguments = params.arguments or {}
    try:
        if name == "fleet_list":
            resources = api_call("GET", "/cluster/resources?type=vm") or []
            guests = [
                {
                    "name": r.get("name"),
                    "vmid": r.get("vmid"),
                    "type": r.get("type"),
                    "status": r.get("status"),
                }
                for r in resources
                if not r.get("template")
            ]
            return _result(guests)

        if name == "fleet_status":
            guest = resolve_guest(arguments["guest"])
            node, vmid, gtype = guest["node"], guest["vmid"], guest["type"]
            path = "qemu" if gtype == "qemu" else "lxc"
            status = api_call("GET", f"/nodes/{node}/{path}/{vmid}/status/current")
            return _result(status)

        if name == "fleet_start":
            guest = resolve_guest(arguments["guest"])
            node, vmid, gtype = guest["node"], guest["vmid"], guest["type"]
            path = "qemu" if gtype == "qemu" else "lxc"
            task = api_call("POST", f"/nodes/{node}/{path}/{vmid}/status/start")
            return _result({"started": guest["name"], "vmid": vmid, "task": task})

        if name == "fleet_stop":
            guest = resolve_guest(arguments["guest"])
            node, vmid, gtype = guest["node"], guest["vmid"], guest["type"]
            path = "qemu" if gtype == "qemu" else "lxc"
            task = api_call("POST", f"/nodes/{node}/{path}/{vmid}/status/stop")
            return _result({"stopped": guest["name"], "vmid": vmid, "task": task})

        if name == "fleet_snapshot":
            guest = resolve_guest(arguments["guest"])
            node, vmid = guest["node"], guest["vmid"]
            snap = arguments["snapshot_name"]
            task = api_call("POST", f"/nodes/{node}/qemu/{vmid}/snapshot", {"snapname": snap})
            return _result({"snapshotted": guest["name"], "vmid": vmid, "snapshot": snap, "task": task})

        return _result({"error": f"unknown tool: {name}"}, is_error=True)

    except Exception as e:
        # Never raise a bare traceback back to the agent — an explicit
        # error field lets the caller (and the human watching) see
        # exactly what happened, same discipline as proxmox_monitor.py.
        return _result({"error": str(e)}, is_error=True)


server = Server(
    "proxmox-fleet",
    version="1.0.0",
    on_list_tools=on_list_tools,
    on_call_tool=on_call_tool,
)


async def main():
    async with stdio_server() as (read_stream, write_stream):
        await server.run(read_stream, write_stream, server.create_initialization_options())


if __name__ == "__main__":
    import asyncio
    asyncio.run(main())
