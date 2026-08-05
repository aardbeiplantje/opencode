import asyncio
import os
import json
import re
import time
from pathlib import Path

import httpx

from mcp.server.stdio import stdio_server
from fastmcp import FastMCP


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


mcp = FastMCP("llama-slot-cache")


@mcp.tool()
async def slot_verify(
    server_url: str | None = None,
    model: str | None = None,
) -> str:
    """Verify that the llama.cpp server supports the /slots API."""
    url = _clean_server_url(server_url or LLAMA_SERVER_URL)
    model_name = model or LLAMA_MODEL

    params = {"model": model_name} if model_name else {}
    slots_url = f"{url}/slots"

    try:
        resp = httpx.get(slots_url, params=params, timeout=30)
        if resp.status_code == 404:
            return "Slots API not supported (404). The server does not expose /slots endpoint."
        resp.raise_for_status()
        slots = resp.json()
        count = len(slots) if isinstance(slots, list) else "unknown"
        return f"Slots API is available. Found {count} slot(s)."
    except httpx.HTTPStatusError as e:
        return f"Slots API error: {e.response.status_code} - {e.response.text}"
    except httpx.HTTPError as e:
        return f"Slots API connection error: {e}"


@mcp.tool()
async def slot_save(
    server_url: str | None = None,
    slot_id: int = 0,
    session_id: str | None = None,
    directory: str | None = None,
    model: str | None = None,
) -> str:
    """Save a slot's KV cache to the llama.cpp server."""
    url = _clean_server_url(server_url or LLAMA_SERVER_URL)
    model_name = model or LLAMA_MODEL

    try:
        slot_id = int(slot_id)
    except (TypeError, ValueError):
        slot_id = 0

    cache_name = _build_cache_name(session_id, directory)
    meta_path = Path(CACHE_BASE_DIR) / ".slot-cache-meta.jsonl"

    save_url = f"{url}/slots/{slot_id}?action=save"
    payload = {"filename": cache_name, "model": model_name} if model_name else {"filename": cache_name}

    try:
        resp = httpx.post(save_url, json=payload, timeout=30)
        resp.raise_for_status()
        result = resp.json()
        saved_name = result.get("filename", cache_name)

        # Persist metadata
        Path(CACHE_BASE_DIR).mkdir(parents=True, exist_ok=True)
        with open(meta_path, "a") as f:
            f.write(json.dumps({
                "action": "save",
                "cache_name": saved_name,
                "file": saved_name,
                "model": model_name,
                "slot_id": slot_id,
                "session_id": session_id,
                "time": time.time()
            }) + "\n")

        return f'Slot {slot_id} saved successfully to cache "{saved_name}".'
    except httpx.HTTPStatusError as e:
        return f"Slot save failed (HTTP {e.response.status_code}): {e.response.text}"
    except httpx.HTTPError as e:
        return f"Slot save error: {e}"


@mcp.tool()
async def slot_restore(
    server_url: str | None = None,
    slot_id: int = 0,
    session_id: str | None = None,
    directory: str | None = None,
    model: str | None = None,
) -> str:
    """Restore a slot's KV cache from the llama.cpp server."""
    url = _clean_server_url(server_url or LLAMA_SERVER_URL)
    model_name = model or LLAMA_MODEL

    try:
        slot_id = int(slot_id)
    except (TypeError, ValueError):
        slot_id = 0

    cache_name = _build_cache_name(session_id, directory)

    restore_url = f"{url}/slots/{slot_id}?action=restore"
    payload = {"filename": cache_name, "model": model_name} if model_name else {"filename": cache_name}

    try:
        resp = httpx.post(restore_url, json=payload, timeout=30)
        resp.raise_for_status()

        # Persist metadata
        meta_path = Path(CACHE_BASE_DIR) / ".slot-cache-meta.jsonl"
        Path(CACHE_BASE_DIR).mkdir(parents=True, exist_ok=True)
        with open(meta_path, "a") as f:
            f.write(json.dumps({
                "action": "restore",
                "cache_name": cache_name,
                "file": cache_name,
                "model": model_name,
                "slot_id": slot_id,
                "session_id": session_id,
                "time": time.time()
            }) + "\n")

        return f'Slot {slot_id} restored from cache "{cache_name}".'
    except httpx.HTTPStatusError as e:
        return f"Slot restore failed (HTTP {e.response.status_code}): {e.response.text}"
    except httpx.HTTPError as e:
        return f"Slot restore error: {e}"


@mcp.tool()
async def slot_check(server_url: str | None = None, session_id: str | None = None, model: str | None = None) -> str:
    """Check if a slot cache exists and is fresh (less than 24h old)."""
    _clean_server_url(server_url or LLAMA_SERVER_URL)

    cache_name = _build_cache_name(session_id)
    meta_path = Path(CACHE_BASE_DIR) / ".slot-cache-meta.jsonl"

    results = []
    if not meta_path.exists():
        return "No cache metadata file found. No caches available."

    try:
        with open(meta_path) as f:
            lines = f.readlines()

        if not lines:
            return "Cache metadata file is empty. No caches available."

        last = json.loads(lines[-1])
        age = time.time() - last.get("time", 0)
        age_min = age / 60

        results.append(f'Cache "{cache_name}" exists.')
        results.append(f"Last action: {last.get('action', 'unknown')}")
        results.append(f"Last modified: {age_min:.1f} minutes ago")

        if age > 86400:
            results.append("WARNING: Cache is older than 24 hours and may be stale.")
        else:
            results.append("Cache is fresh (less than 24h old).")
    except (json.JSONDecodeError, IOError) as e:
        return f"Error reading cache metadata: {e}"

    return "\n".join(results)


@mcp.tool()
async def slot_list_caches(model: str | None = None, session_id: str | None = None) -> str:
    """List all available cached slots with metadata (filename, size, timestamps)."""
    meta_path = Path(CACHE_BASE_DIR) / ".slot-cache-meta.jsonl"

    if not meta_path.exists():
        return "No cache metadata file found. No caches available."

    try:
        with open(meta_path) as f:
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
            if session_id and entry.get("session_id") != session_id:
                continue

            # Skip incompatible
            if entry.get("action") == "unavailable":
                continue

            entries.append(entry)

        if not entries:
            return "No caches match the specified filters."

        results = [f"Found {len(entries)} cached slot(s):\n"]
        for i, entry in enumerate(entries, 1):
            cache_file = entry.get("file", "N/A")
            action = entry.get("action", "unknown")
            ts = entry.get("time", 0)
            age_min = (time.time() - ts) / 60
            sess = entry.get("session_id", "N/A")

            results.append(f"  {i}. {cache_file}")
            results.append(f"     Action: {action}, Session: {sess}")
            results.append(f"     Modified: {age_min:.1f} minutes ago")

            # Check if .kv file exists
            kv_path = Path(CACHE_BASE_DIR) / cache_file
            if kv_path.exists():
                size = kv_path.stat().st_size
                results.append(f"     Size: {size:,} bytes")
                results.append(f"     Path: {kv_path}")
            else:
                results.append(f"     WARNING: .kv file missing! ({kv_path})")

        return "\n".join(results)
    except IOError as e:
        return f"Error reading cache metadata: {e}"


@mcp.tool()
async def slot_delete(cache_name: str | None = None, model: str | None = None) -> str:
    """Delete a cached slot. Without session_id, lists available caches for confirmation."""
    _clean_server_url(LLAMA_SERVER_URL)

    if not cache_name:
        list_result = await slot_list_caches(model=model)
        return f"Available caches (provide --cache-name to delete):\n\n{list_result}"

    try:
        kv_path = Path(CACHE_BASE_DIR) / cache_name
        meta_path = Path(CACHE_BASE_DIR) / ".slot-cache-meta.jsonl"

        if kv_path.exists():
            kv_path.unlink()

            # Remove from metadata file
            if meta_path.exists():
                with open(meta_path) as f:
                    lines = f.readlines()

                with open(meta_path, "w") as f:
                    for line in lines:
                        try:
                            entry = json.loads(line.strip())
                            if entry.get("cache_name") != cache_name:
                                f.write(line)
                        except json.JSONDecodeError:
                            f.write(line)

            return f'Cache "{cache_name}" deleted successfully.'
        else:
            return f"Cache file not found: {kv_path}"
    except Exception as e:
        return f"Delete error: {e}"


if __name__ == "__main__":
    mcp.run()
