#!/usr/bin/env python3
"""
MCP (Model Context Protocol) Server for Decodium AI Agent.

Exposes Decodium/ham radio tools as MCP tools that the LLM can call.
Communicates via stdio transport (JSON-RPC 2.0).
"""

import json
import subprocess
import sys
import os
import shlex
import asyncio
from typing import Dict, Any, List, Optional
from dataclasses import dataclass, asdict

# Tool definitions - each tool the AI can invoke
TOOLS = [
    {
        "name": "run_command",
        "description": "Execute a shell command and return stdout/stderr/exit code. Use for any command not covered by more specific tools.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "command": {"type": "string", "description": "Shell command to execute"},
                "timeout": {"type": "integer", "description": "Timeout in seconds", "default": 30},
                "cwd": {"type": "string", "description": "Working directory", "default": "/"}
            },
            "required": ["command"]
        }
    },
    {
        "name": "rigctl",
        "description": "Control a radio via Hamlib rigctl (CAT control). Get/set frequency, mode, PTT, etc.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "command": {"type": "string", "description": "rigctl command (e.g., 'f', 'm', 'M', 'T', 't', 'v', 'V', 'u', 'U', 'w', 'W', 'x', 'X', 'y', 'Y', 'z', 'Z', 'l', 'L', 'p', 'P')"},
                "args": {"type": "string", "description": "Arguments for the command (e.g., '14074000 USB' for 'M')"},
                "rig_model": {"type": "integer", "description": "Hamlib rig model number (default: 2 for Hamlib NET rigctl)", "default": 2},
                "device": {"type": "string", "description": "Device path or host:port (default: localhost:4532)", "default": "localhost:4532"}
            },
            "required": ["command"]
        }
    },
    {
        "name": "decodium_rx",
        "description": "Decode FT8/FT4/FT2 audio using decodium-rx (receive-only decoder).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "mode": {"type": "string", "enum": ["ft8", "ft4", "ft2"], "description": "Mode to decode"},
                "wav_file": {"type": "string", "description": "Path to WAV file to decode"},
                "freq_hz": {"type": "integer", "description": "Center frequency in Hz", "default": 1500},
                "no_log": {"type": "boolean", "description": "Suppress log output", "default": true},
                "no_color": {"type": "boolean", "description": "Disable ANSI colors", "default": true}
            },
            "required": ["mode", "wav_file"]
        }
    },
    {
        "name": "wsjtx",
        "description": "Control WSJT-X via its UDP network protocol (send commands, read status).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "action": {"type": "string", "enum": ["get_status", "set_frequency", "set_mode", "start_tx", "stop_tx", "log_qso", "clear_log"], "description": "Action to perform"},
                "frequency": {"type": "integer", "description": "Frequency in Hz (for set_frequency)"},
                "mode": {"type": "string", "description": "Mode name (for set_mode, e.g., FT8, FT4, FT2)"},
                "host": {"type": "string", "description": "WSJT-X UDP host", "default": "127.0.0.1"},
                "port": {"type": "integer", "description": "WSJT-X UDP port", "default": 2237}
            },
            "required": ["action"]
        }
    },
    {
        "name": "gpredict",
        "description": "Query Gpredict for satellite passes, position, or tracking info.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "action": {"type": "string", "enum": ["list_satellites", "next_pass", "current_position", "doppler"], "description": "Action to perform"},
                "satellite": {"type": "string", "description": "Satellite name (for next_pass, current_position, doppler)"},
                "location": {"type": "string", "description": "Ground station location (lat,lon,alt)", "default": "0,0,0"},
                "start_time": {"type": "string", "description": "Start time ISO format (for next_pass)", "default": "now"},
                "duration_hours": {"type": "number", "description": "Hours to look ahead (for next_pass)", "default": 24}
            },
            "required": ["action"]
        }
    },
    {
        "name": "hamlib_rotctl",
        "description": "Control antenna rotator via Hamlib rotctl.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "command": {"type": "string", "enum": ["p", "P", "v", "V", "s", "S", "h", "H"], "description": "rotctl command: p=position, P=set position, v=version, V=set position relative, s=stop, S=stop, h=help, H=halt"},
                "args": {"type": "string", "description": "Arguments (e.g., '180 45' for azimuth elevation)"},
                "model": {"type": "integer", "description": "Hamlib rotator model number", "default": 1},
                "device": {"type": "string", "description": "Device path or host:port", "default": "localhost:4533"}
            },
            "required": ["command"]
        }
    },
    {
        "name": "apt_install",
        "description": "Install a Debian package via apt (requires root). Use for installing ham radio software.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "packages": {"type": "array", "items": {"type": "string"}, "description": "Package names to install"},
                "update_first": {"type": "boolean", "description": "Run apt update first", "default": true}
            },
            "required": ["packages"]
        }
    },
    {
        "name": "journalctl",
        "description": "Query systemd journal for logs (decodium, rigctld, wsjtx, etc.).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "unit": {"type": "string", "description": "Systemd unit name (e.g., 'rigctld', 'wsjtx', 'decodium-rx')"},
                "lines": {"type": "integer", "description": "Number of lines to show", "default": 50},
                "follow": {"type": "boolean", "description": "Follow output (-f)", "default": false},
                "since": {"type": "string", "description": "Since timestamp (e.g., '1 hour ago', '2024-01-01')"},
                "grep": {"type": "string", "description": "Filter output with grep pattern"}
            },
            "required": []
        }
    },
    {
        "name": "audio_devices",
        "description": "List audio input/output devices (for radio sound card configuration).",
        "inputSchema": {
            "type": "object",
            "properties": {
                "type": {"type": "string", "enum": ["input", "output", "all"], "description": "Device type to list", "default": "all"}
            },
            "required": []
        }
    },
    {
        "name": "decodium_version",
        "description": "Get installed Decodium version and info.",
        "inputSchema": {
            "type": "object",
            "properties": {},
            "required": []
        }
    }
]


@dataclass
class ToolResult:
    success: bool
    output: str
    error: str = ""
    exit_code: int = 0


async def run_command(args: Dict[str, Any]) -> ToolResult:
    """Execute a shell command."""
    cmd = args["command"]
    timeout = args.get("timeout", 30)
    cwd = args.get("cwd", "/")
    try:
        proc = await asyncio.create_subprocess_shell(
            cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=cwd
        )
        stdout, stderr = await asyncio.wait_for(proc.communicate(), timeout=timeout)
        return ToolResult(
            success=proc.returncode == 0,
            output=stdout.decode("utf-8", errors="replace"),
            error=stderr.decode("utf-8", errors="replace"),
            exit_code=proc.returncode
        )
    except asyncio.TimeoutError:
        return ToolResult(success=False, output="", error=f"Command timed out after {timeout}s", exit_code=-1)
    except Exception as e:
        return ToolResult(success=False, output="", error=str(e), exit_code=-1)


async def rigctl_tool(args: Dict[str, Any]) -> ToolResult:
    """Control radio via rigctl."""
    cmd = args["command"]
    cmd_args = args.get("args", "")
    model = args.get("rig_model", 2)
    device = args.get("device", "localhost:4532")

    full_cmd = f"rigctl -m {model} -r {device} {cmd}"
    if cmd_args:
        full_cmd += f" {cmd_args}"

    return await run_command({"command": full_cmd, "timeout": 10})


async def decodium_rx_tool(args: Dict[str, Any]) -> ToolResult:
    """Decode audio with decodium-rx."""
    mode = args["mode"]
    wav_file = args["wav_file"]
    freq_hz = args.get("freq_hz", 1500)
    no_log = args.get("no_log", True)
    no_color = args.get("no_color", True)

    cmd = f"decodium-rx --no-log --no-color -m {mode} --wav {shlex.quote(wav_file)}"
    if freq_hz != 1500:
        cmd += f" --freq {freq_hz}"

    return await run_command({"command": cmd, "timeout": 60})


async def wsjtx_tool(args: Dict[str, Any]) -> ToolResult:
    """Control WSJT-X via UDP. Uses wsjtx-udp-cli if available, else netcat."""
    action = args["action"]
    host = args.get("host", "127.0.0.1")
    port = args.get("port", 2237)

    # This is a simplified implementation - real WSJT-X control needs proper UDP protocol
    if action == "get_status":
        cmd = f"echo 'get_status' | nc -u -w 2 {host} {port}"
    elif action == "set_frequency":
        freq = args.get("frequency", 14074000)
        cmd = f"echo 'set_frequency {freq}' | nc -u -w 2 {host} {port}"
    elif action == "set_mode":
        mode = args.get("mode", "FT8")
        cmd = f"echo 'set_mode {mode}' | nc -u -w 2 {host} {port}"
    else:
        return ToolResult(success=False, output="", error=f"Unsupported WSJT-X action: {action}", exit_code=1)

    return await run_command({"command": cmd, "timeout": 5})


async def gpredict_tool(args: Dict[str, Any]) -> ToolResult:
    """Query Gpredict via its CLI or D-Bus."""
    action = args["action"]

    if action == "list_satellites":
        cmd = "gpredict --list-satellites 2>/dev/null || gpredict -l 2>/dev/null || echo 'Gpredict CLI not available'"
    elif action == "next_pass":
        sat = args.get("satellite", "")
        loc = args.get("location", "0,0,0")
        start = args.get("start_time", "now")
        dur = args.get("duration_hours", 24)
        cmd = f"gpredict --next-pass '{sat}' --location '{loc}' --start '{start}' --duration {dur} 2>/dev/null || echo 'Gpredict CLI not available'"
    elif action == "current_position":
        sat = args.get("satellite", "")
        cmd = f"gpredict --position '{sat}' 2>/dev/null || echo 'Gpredict CLI not available'"
    elif action == "doppler":
        sat = args.get("satellite", "")
        freq = args.get("frequency", 145800000)
        cmd = f"gpredict --doppler '{sat}' --frequency {freq} 2>/dev/null || echo 'Gpredict CLI not available'"
    else:
        return ToolResult(success=False, output="", error=f"Unknown gpredict action: {action}", exit_code=1)

    return await run_command({"command": cmd, "timeout": 10})


async def rotctl_tool(args: Dict[str, Any]) -> ToolResult:
    """Control rotator via rotctl."""
    cmd = args["command"]
    cmd_args = args.get("args", "")
    model = args.get("model", 1)
    device = args.get("device", "localhost:4533")

    full_cmd = f"rotctl -m {model} -r {device} {cmd}"
    if cmd_args:
        full_cmd += f" {cmd_args}"

    return await run_command({"command": full_cmd, "timeout": 10})


async def apt_install_tool(args: Dict[str, Any]) -> ToolResult:
    """Install packages via apt."""
    packages = " ".join(args["packages"])
    update_first = args.get("update_first", True)

    cmd = ""
    if update_first:
        cmd += "apt update && "
    cmd += f"DEBIAN_FRONTEND=noninteractive apt install -y {packages}"

    return await run_command({"command": cmd, "timeout": 300})


async def journalctl_tool(args: Dict[str, Any]) -> ToolResult:
    """Query systemd journal."""
    unit = args.get("unit", "")
    lines = args.get("lines", 50)
    follow = args.get("follow", False)
    since = args.get("since", "")
    grep = args.get("grep", "")

    cmd = "journalctl"
    if unit:
        cmd += f" -u {unit}"
    cmd += f" -n {lines}"
    if follow:
        cmd += " -f"
    if since:
        cmd += f" --since '{since}'"
    if grep:
        cmd += f" | grep -i {shlex.quote(grep)}"

    return await run_command({"command": cmd, "timeout": 10})


async def audio_devices_tool(args: Dict[str, Any]) -> ToolResult:
    """List audio devices."""
    dtype = args.get("type", "all")

    if dtype in ("input", "all"):
        cmd_in = "pactl list short sources 2>/dev/null || arecord -l 2>/dev/null || echo 'No audio input tools'"
    else:
        cmd_in = ""

    if dtype in ("output", "all"):
        cmd_out = "pactl list short sinks 2>/dev/null || aplay -l 2>/dev/null || echo 'No audio output tools'"
    else:
        cmd_out = ""

    cmds = [c for c in [cmd_in, cmd_out] if c]
    cmd = " && echo '---' && ".join(cmds)

    return await run_command({"command": cmd, "timeout": 10})


async def decodium_version_tool(args: Dict[str, Any]) -> ToolResult:
    """Get Decodium version."""
    cmd = "decodium --version 2>/dev/null || dpkg -l decodium 2>/dev/null | grep ^ii || echo 'Decodium not installed'"
    return await run_command({"command": cmd, "timeout": 5})


TOOL_HANDLERS = {
    "run_command": run_command,
    "rigctl": rigctl_tool,
    "decodium_rx": decodium_rx_tool,
    "wsjtx": wsjtx_tool,
    "gpredict": gpredict_tool,
    "hamlib_rotctl": rotctl_tool,
    "apt_install": apt_install_tool,
    "journalctl": journalctl_tool,
    "audio_devices": audio_devices_tool,
    "decodium_version": decodium_version_tool,
}


async def handle_request(request: Dict[str, Any]) -> Dict[str, Any]:
    """Handle a JSON-RPC request."""
    method = request.get("method")
    params = request.get("params", {})
    req_id = request.get("id")

    if method == "initialize":
        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {
                "protocolVersion": "2024-11-05",
                "capabilities": {
                    "tools": {}
                },
                "serverInfo": {
                    "name": "decodium-ai-mcp",
                    "version": "1.0.0"
                }
            }
        }

    elif method == "tools/list":
        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "result": {"tools": TOOLS}
        }

    elif method == "tools/call":
        tool_name = params.get("name")
        tool_args = params.get("arguments", {})

        handler = TOOL_HANDLERS.get(tool_name)
        if not handler:
            return {
                "jsonrpc": "2.0",
                "id": req_id,
                "error": {"code": -32601, "message": f"Unknown tool: {tool_name}"}
            }

        try:
            result = await handler(tool_args)
            return {
                "jsonrpc": "2.0",
                "id": req_id,
                "result": {
                    "content": [
                        {
                            "type": "text",
                            "text": json.dumps(asdict(result), ensure_ascii=False)
                        }
                    ]
                }
            }
        except Exception as e:
            return {
                "jsonrpc": "2.0",
                "id": req_id,
                "error": {"code": -32603, "message": f"Tool error: {str(e)}"}
            }

    else:
        return {
            "jsonrpc": "2.0",
            "id": req_id,
            "error": {"code": -32601, "message": f"Unknown method: {method}"}
        }


async def main():
    """Main MCP server loop - reads JSON-RPC from stdin, writes to stdout."""
    # Send initialization notification
    init_notification = {
        "jsonrpc": "2.0",
        "method": "notifications/initialized",
        "params": {}
    }
    print(json.dumps(init_notification), flush=True)

    while True:
        try:
            line = await asyncio.get_event_loop().run_in_executor(None, sys.stdin.readline)
            if not line:
                break
            line = line.strip()
            if not line:
                continue

            request = json.loads(line)
            response = await handle_request(request)
            print(json.dumps(response, ensure_ascii=False), flush=True)

        except json.JSONDecodeError:
            continue
        except EOFError:
            break
        except Exception as e:
            error_response = {
                "jsonrpc": "2.0",
                "id": None,
                "error": {"code": -32603, "message": f"Server error: {str(e)}"}
            }
            print(json.dumps(error_response), flush=True)


if __name__ == "__main__":
    asyncio.run(main())