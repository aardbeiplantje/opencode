import asyncio
import sys
import os
import json
import re
import httpx
from pathlib import Path
from mcp.server.models import InitializationOptions
import mcp.types as types
from mcp.server import NotificationOptions, Server
from mcp.server.stdio import stdio_server

server = Server("llama-slot-cache")

def _clean_server_url(url):
    """Remove /v1 suffix from llama.cpp server URL."""
    if url.endswith("/v1"):
        return url[:-3]
    if "/v1/" in url:
        return url.split("/v1/")[0]
    return url

LLAMA_SERVER_URL = _clean_server_url(os.environ.get("LLAMA_SERVER_URL", "http://[::1]:8000"))
LLAMA_MODEL = os.environ.get("LLAMA_MODEL", "")
CACHE_BASE_DIR = "/home/node/.cache/llama-slots"


def _build_cache_name(session_id=None, directory=None):
    """Build a namespaced cache name based on model, session, and project directory.
    
    Matches the plugin's makeCacheName() in manifest.js for consistency.
    """
    user = os.environ.get("UID") or os.environ.get("USER") or os.environ.get("LOGNAME") or "node"
    model_id = LLAMA_MODEL or "default"
    model_short = re.sub(r'[^a-zA-Z0-9]', '_', model_id.split("/")[-1].split(":")[0])[:30]
    session_part = (session_id or "none")[:8]
    
    if directory:
        parts = [p for p in directory.split("/") if p]
        base = re.sub(r'[^a-zA-Z0-9]', '_', parts[-1])[:30]
        return f"{user}_{model_short}_{base}_{session_part}"
    else:
        return f"{user}_{model_short}_root_{session_part}"


@server.list_tools()
async def handle_list_tools() -> list[types.Tool]:
    return [
        types.Tool(
            name="slot_verify",
            description="Verify that the llama.cpp server supports the /slots API",
            inputSchema={
                "type": "object",
                "properties": {
                    "server_url": {
                        "type": "string",
                        "description": "llama.cpp server base URL (default: from LLAMA_SERVER_URL env var)"
                    },
                    "model": {
                        "type": "string",
                        "description": "Model name to check against (optional)"
                    }
                },
                "required": [],
            },
        ),
        types.Tool(
            name="slot_save",
            description="Save a slot's KV cache to the llama.cpp server",
            inputSchema={
                "type": "object",
                "properties": {
                    "server_url": {
                        "type": "string",
                        "description": "llama.cpp server base URL (default: from LLAMA_SERVER_URL env var)"
                    },
                    "slot_id": {
                        "type": "integer",
                        "description": "Slot ID to save (default: from SLOT_ID env var, 0)"
                    },
                    "session_id": {
                        "type": "string",
                        "description": "Session ID for cache naming (optional, uses model-based name if omitted)"
                    },
                    "model": {
                        "type": "string",
                        "description": "Model name (default: from LLAMA_MODEL env var)"
                    }
                },
                "required": [],
            },
        ),
        types.Tool(
            name="slot_restore",
            description="Restore a slot's KV cache from the llama.cpp server",
            inputSchema={
                "type": "object",
                "properties": {
                    "server_url": {
                        "type": "string",
                        "description": "llama.cpp server base URL (default: from LLAMA_SERVER_URL env var)"
                    },
                    "slot_id": {
                        "type": "integer",
                        "description": "Slot ID to restore (default: from SLOT_ID env var, 0)"
                    },
                    "session_id": {
                        "type": "string",
                        "description": "Session ID for cache naming (optional, uses model-based name if omitted)"
                    },
                    "model": {
                        "type": "string",
                        "description": "Model name (default: from LLAMA_MODEL env var)"
                    }
                },
                "required": [],
            },
        ),
        types.Tool(
            name="slot_check",
            description="Check if a slot cache exists and is fresh (less than 24h old)",
            inputSchema={
                "type": "object",
                "properties": {
                    "server_url": {
                        "type": "string",
                        "description": "llama.cpp server base URL (default: from LLAMA_SERVER_URL env var)"
                    },
                    "session_id": {
                        "type": "string",
                        "description": "Session ID for cache checking (optional)"
                    },
                    "model": {
                        "type": "string",
                        "description": "Model name (default: from LLAMA_MODEL env var)"
                    }
                },
                "required": [],
            },
        ),
        types.Tool(
            name="slot_list_caches",
            description="List all available cached slots with metadata (filename, size, timestamps)",
            inputSchema={
                "type": "object",
                "properties": {
                    "model": {
                        "type": "string",
                        "description": "Filter by model name (optional)"
                    },
                    "session_id": {
                        "type": "string",
                        "description": "Filter by session ID (optional)"
                    }
                },
                "required": [],
            },
        ),
        types.Tool(
            name="slot_delete",
            description="Delete a cached slot. Without session_id, lists available caches for confirmation.",
            inputSchema={
                "type": "object",
                "properties": {
                    "cache_name": {
                        "type": "string",
                        "description": "Cache name to delete (e.g. node_model_short_sessionid). If omitted, lists available caches first."
                    },
                    "model": {
                        "type": "string",
                        "description": "Model name for filtering (default: from LLAMA_MODEL env var)"
                    }
                },
                "required": [],
            },
        ),
    ]


@server.call_tool()
async def handle_call_tool(
    name: str, arguments: dict | None
) -> list[types.TextContent | types.ImageContent | types.EmbeddedResource]:
    from pathlib import Path
    import time
    
    server_url = (arguments or {}).get("server_url", LLAMA_SERVER_URL) if arguments else LLAMA_SERVER_URL
    model = (arguments or {}).get("model", LLAMA_MODEL) if arguments else LLAMA_MODEL
    slot_id = (arguments or {}).get("slot_id", 0) if arguments else 0
    try:
        slot_id = int(slot_id)
    except (TypeError, ValueError):
        slot_id = 0

    user = os.environ.get("UID") or os.environ.get("USER") or os.environ.get("LOGNAME") or "node"
    
    if name == "slot_verify":
        params = {"model": model} if model else {}
        url = f"{server_url}/slots"
        try:
            resp = httpx.get(url, params=params, timeout=30)
            if resp.status_code == 404:
                return [types.TextContent(type="text", text=f"Slots API not supported (404). The server does not expose /slots endpoint.")]
            resp.raise_for_status()
            slots = resp.json()
            count = len(slots) if isinstance(slots, list) else "unknown"
            return [types.TextContent(type="text", text=f"Slots API is available. Found {count} slot(s).")]
        except httpx.HTTPStatusError as e:
            return [types.TextContent(type="text", text=f"Slots API error: {e.response.status_code} - {e.response.text}")]
        except httpx.HTTPError as e:
            return [types.TextContent(type="text", text=f"Slots API connection error: {e}")]

    elif name == "slot_save":
        session_id = (arguments or {}).get("session_id") if arguments else None
        directory = (arguments or {}).get("directory") if arguments else None
        cache_name = _build_cache_name(session_id, directory)
        cache_dir = CACHE_BASE_DIR
        meta = Path(cache_dir) / ".slot-cache-meta.jsonl"
        
        # Save slot KV cache via the llama.cpp /slots/{slot_id}?action=save REST API
        try:
            url = f"{server_url}/slots/{slot_id}?action=save"
            payload = {"filename": cache_name, "model": model} if model else {"filename": cache_name}
            resp = httpx.post(url, json=payload, timeout=30)
            resp.raise_for_status()
            result = resp.json()
            saved_name = result.get("filename", cache_name)
            # Persist metadata
            cache_dir_obj = Path(cache_dir)
            cache_dir_obj.mkdir(parents=True, exist_ok=True)
            with open(meta, "a") as f:
                f.write(json.dumps({
                    "action": "save",
                    "cache_name": saved_name,
                    "file": saved_name,
                    "model": model,
                    "slot_id": slot_id,
                    "session_id": session_id,
                    "time": time.time()
                }) + "\n")
            return [types.TextContent(type="text", text=f"Slot {slot_id} saved successfully to cache \"{saved_name}\".")]
        except httpx.HTTPStatusError as e:
            return [types.TextContent(type="text", text=f"Slot save failed (HTTP {e.response.status_code}): {e.response.text}")]
        except httpx.HTTPError as e:
            return [types.TextContent(type="text", text=f"Slot save error: {e}")]

    elif name == "slot_restore":
        session_id = (arguments or {}).get("session_id") if arguments else None
        directory = (arguments or {}).get("directory") if arguments else None
        cache_name = _build_cache_name(session_id, directory)
        cache_dir = CACHE_BASE_DIR
        
        # Restore slot KV cache via the llama.cpp /slots/{slot_id}?action=restore REST API
        try:
            url = f"{server_url}/slots/{slot_id}?action=restore"
            payload = {"filename": cache_name, "model": model} if model else {"filename": cache_name}
            resp = httpx.post(url, json=payload, timeout=30)
            resp.raise_for_status()
            result = resp.json()
            # Persist metadata
            meta = Path(cache_dir) / ".slot-cache-meta.jsonl"
            cache_dir_obj = Path(cache_dir)
            cache_dir_obj.mkdir(parents=True, exist_ok=True)
            with open(meta, "a") as f:
                f.write(json.dumps({
                    "action": "restore",
                    "cache_name": cache_name,
                    "file": cache_name,
                    "model": model,
                    "slot_id": slot_id,
                    "session_id": session_id,
                    "time": time.time()
                }) + "\n")
            return [types.TextContent(type="text", text=f"Slot {slot_id} restored from cache \"{cache_name}\".")]
        except httpx.HTTPStatusError as e:
            return [types.TextContent(type="text", text=f"Slot restore failed (HTTP {e.response.status_code}): {e.response.text}")]
        except httpx.HTTPError as e:
            return [types.TextContent(type="text", text=f"Slot restore error: {e}")]

    elif name == "slot_check":
        session_id = (arguments or {}).get("session_id") if arguments else None
        cache_name = _build_cache_name(session_id)
        cache_dir = CACHE_BASE_DIR
        meta = Path(cache_dir) / ".slot-cache-meta.jsonl"
        
        results = []
        if not meta.exists():
            results.append("No cache metadata file found. No caches available.")
        else:
            try:
                with open(meta) as f:
                    lines = f.readlines()
                if not lines:
                    results.append("Cache metadata file is empty. No caches available.")
                else:
                    last = json.loads(lines[-1])
                    age = time.time() - last.get("time", 0)
                    age_min = age / 60
                    results.append(f"Cache \"{cache_name}\" exists.")
                    results.append(f"Last action: {last.get('action', 'unknown')}")
                    results.append(f"Last modified: {age_min:.1f} minutes ago")
                    if age > 86400:
                        results.append("WARNING: Cache is older than 24 hours and may be stale.")
                    else:
                        results.append("Cache is fresh (less than 24h old).")
            except (json.JSONDecodeError, IOError) as e:
                results.append(f"Error reading cache metadata: {e}")
        
        return [types.TextContent(type="text", text="\n".join(results))]

    elif name == "slot_list_caches":
        cache_dir = CACHE_BASE_DIR
        meta = Path(cache_dir) / ".slot-cache-meta.jsonl"
        
        results = []
        if not meta.exists():
            return [types.TextContent(type="text", text="No cache metadata file found. No caches available.")]
        
        try:
            with open(meta) as f:
                lines = f.readlines()
            
            entries = []
            for line in lines:
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                except json.JSONDecodeError:
                    continue
                
                # Filter by model
                if model and entry.get("model") != model:
                    continue
                
                # Filter by session_id
                session_filter = (arguments or {}).get("session_id") if arguments else None
                if session_filter and entry.get("session_id") != session_filter:
                    continue
                
                # Skip incompatible
                if entry.get("action") == "unavailable":
                    continue
                
                entries.append(entry)
            
            if not entries:
                return [types.TextContent(type="text", text="No caches match the specified filters.")]
            
            results.append(f"Found {len(entries)} cached slot(s):\n")
            for i, entry in enumerate(entries, 1):
                cache_file = entry.get("file", "N/A")
                action = entry.get("action", "unknown")
                ts = entry.get("time", 0)
                age_min = (time.time() - ts) / 60
                session = entry.get("session_id", "N/A")
                results.append(f"  {i}. {cache_file}")
                results.append(f"     Action: {action}, Session: {session}")
                results.append(f"     Modified: {age_min:.1f} minutes ago")
                
                # Check if .kv file exists
                kv_path = Path(cache_dir) / cache_file
                if kv_path.exists():
                    size = kv_path.stat().st_size
                    results.append(f"     Size: {size:,} bytes")
                    results.append(f"     Path: {kv_path}")
                else:
                    results.append(f"     WARNING: .kv file missing! ({kv_path})")
            
            return [types.TextContent(type="text", text="\n".join(results))]
        except IOError as e:
            return [types.TextContent(type="text", text=f"Error reading cache metadata: {e}")]

    elif name == "slot_delete":
        cache_dir = CACHE_BASE_DIR
        cache_name_arg = (arguments or {}).get("cache_name") if arguments else None
        
        if not cache_name_arg:
            # List available caches for confirmation
            list_result = await handle_call_tool("slot_list_caches", arguments)
            return [types.TextContent(type="text", text=f"Available caches (provide --cache-name to delete):\n\n{list_result[0].text}")]
        
        # Delete the KV cache file directly
        try:
            kv_path = Path(cache_dir) / cache_name_arg
            meta = Path(cache_dir) / ".slot-cache-meta.jsonl"
            
            if kv_path.exists():
                kv_path.unlink()
                # Remove from metadata file
                if meta.exists():
                    with open(meta) as f:
                        lines = f.readlines()
                    with open(meta, "w") as f:
                        for line in lines:
                            try:
                                entry = json.loads(line.strip())
                                if entry.get("cache_name") != cache_name_arg:
                                    f.write(line)
                            except json.JSONDecodeError:
                                f.write(line)
                return [types.TextContent(type="text", text=f"Cache \"{cache_name_arg}\" deleted successfully.")]
            else:
                return [types.TextContent(type="text", text=f"Cache file not found: {kv_path}")]
        except Exception as e:
            return [types.TextContent(type="text", text=f"Delete error: {e}")]

    else:
        raise ValueError(f"Unknown tool: {name}")


PLUGIN_DIR = "/mcp/llama-slot-cache"

async def main():
    async with stdio_server() as (read_stream, write_stream):
        await server.run(
            read_stream,
            write_stream,
            InitializationOptions(
                server_name="llama-slot-cache",
                server_version="0.1.0",
                capabilities=server.get_capabilities(
                    notification_options=NotificationOptions(),
                    experimental_capabilities={},
                ),
            ),
        )

if __name__ == "__main__":
    asyncio.run(main())
