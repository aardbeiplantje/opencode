#!/usr/bin/env python3
"""
llama.cpp slot cache manager for OpenCode.

Manages KV cache persistence via llama.cpp server's /slots API.
Saves slot state to remote server, restores on session start.

Usage:
    python3 slot_cache.py <command> <server_url> <slot_id> <cache_name> <cache_dir>

Commands:
    save     - Save slot KV cache to remote server
    restore  - Restore slot KV cache from remote server
    check    - Check if a valid cache file exists for this slot
"""
import sys
import os
import time
import json
import argparse
import httpx
from pathlib import Path


def save_slot(server_url, slot_id, cache_name, cache_dir, model=None):
    """Save slot KV cache by POSTing to llama.cpp server."""
    cache_file = f"{cache_name}.kv"
    payload = {"filename": cache_file, "model": model or ""}

    # Try POST /slots/{id}?action=save
    url = f"{server_url}/slots/{slot_id}?action=save"
    resp = httpx.post(url, json=payload, timeout=30)
    resp.raise_for_status()

    # Update metadata
    _update_meta(cache_dir, {"action": "save", "slot": slot_id, "file": cache_file, "time": time.time()})
    return True


def restore_slot(server_url, slot_id, cache_name, cache_dir, model=None):
    """Restore slot KV cache by POSTing to llama.cpp server."""
    # Check if cache exists
    if not _check_meta_exists(cache_dir):
        return False

    cache_file = f"{cache_name}.kv"
    payload = {"filename": cache_file, "model": model or ""}

    try:
        url = f"{server_url}/slots/{slot_id}?action=restore"
        resp = httpx.post(url, json=payload, timeout=30)
        resp.raise_for_status()
        _update_meta(cache_dir, {"action": "restore", "slot": slot_id, "file": cache_file, "time": time.time()})
        return True
    except httpx.HTTPError:
        return False


def check_cache(cache_name, cache_dir):
    """Check if cache metadata exists and is recent (< 24 hours)."""
    return _check_meta_exists(cache_dir)


def _check_meta_exists(cache_dir):
    """Check if meta file exists and is not empty."""
    meta = Path(cache_dir) / ".slot-cache-meta.jsonl"
    if not meta.exists():
        return False
    try:
        size = meta.stat().st_size
        if size == 0:
            return False
        # Check if last entry is recent (< 24 hours)
        with open(meta) as f:
            lines = f.readlines()
            if lines:
                last = json.loads(lines[-1])
                age = time.time() - last.get("time", 0)
                return age < 86400  # 24 hours
    except (json.JSONDecodeError, IOError, KeyError):
        return False
    return False


def _update_meta(cache_dir, entry):
    """Append metadata entry to meta file."""
    Path(cache_dir).mkdir(parents=True, exist_ok=True)
    meta = Path(cache_dir) / ".slot-cache-meta.jsonl"
    with open(meta, "a") as f:
        f.write(json.dumps(entry) + "\n")


def main():
    parser = argparse.ArgumentParser(description="llama.cpp slot cache manager")
    parser.add_argument("command", choices=["save", "restore", "check"])
    parser.add_argument("server_url", help="llama.cpp server base URL (e.g. http://[::1]:4000)")
    parser.add_argument("slot_id", type=int, help="Slot ID to manage")
    parser.add_argument("cache_name", help="Cache name (namespaced, e.g. user@dir)")
    parser.add_argument("cache_dir", help="Directory for cache metadata files")
    parser.add_argument("--model", default=None, help="Model name (optional, defaults to server's active model)")
    args = parser.parse_args()

    try:
        if args.command == "save":
            save_slot(args.server_url, args.slot_id, args.cache_name, args.cache_dir, model=args.model)
        elif args.command == "restore":
            sys.exit(0 if restore_slot(args.server_url, args.slot_id, args.cache_name, args.cache_dir) else 1)
        elif args.command == "check":
            sys.exit(0 if check_cache(args.cache_name, args.cache_dir) else 1)
    except httpx.HTTPStatusError as e:
        print(f"[slot-cache] HTTP error: {e.response.status_code} - {e.response.text}", file=sys.stderr)
        sys.exit(1)
    except httpx.ConnectError as e:
        print(f"[slot-cache] Connection error: {e}", file=sys.stderr)
        sys.exit(1)
    except Exception as e:
        print(f"[slot-cache] Error: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
