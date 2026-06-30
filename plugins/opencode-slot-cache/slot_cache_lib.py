import time
import json
import logging
import httpx
from pathlib import Path

_logger = logging.getLogger('slot-cache')


def set_logger(logger):
    """Set the shared logger for slot_cache_lib functions."""
    global _logger
    _logger = logger


def _log(level, message, **kwargs):
    """Log a message using the shared logger, ignoring errors."""
    try:
        fn = getattr(_logger, level, None)
        if fn:
            fn(message, **kwargs)
    except Exception:
        pass


def save_slot(server_url, slot_id, cache_name, cache_dir, model=None):
    """Save slot KV cache by POSTing to llama.cpp server."""
    _log('info', f"save_slot start: slot={slot_id} cache={cache_name} server={server_url} model={model}")
    payload = {"filename": cache_name, "model": model} if model else {"filename": cache_name}

    url = f"{server_url}/slots/{slot_id}?action=save"
    try:
        _log('debug', f"save_slot POST to {url}")
        resp = httpx.post(url, json=payload, timeout=30)
        resp.raise_for_status()
        _log('info', f"save_slot OK: slot={slot_id} cache={cache_name}")
    except httpx.HTTPStatusError as e:
        if e.response.status_code == 404:
            _log('warning', f"save_slot FAILED: slots API not supported (404), server={server_url}")
            _update_meta(cache_dir, {
                "action": "unavailable",
                "server": server_url,
                "reason": "slots API not supported",
                "time": time.time()
            })
            return False
        _log('error', f"save_slot HTTP error: {e.response.status_code} - {e.response.text}")
        raise
    except httpx.HTTPError as e:
        _log('error', f"save_slot error: {e}")
        raise

    _update_meta(cache_dir, {"action": "save", "slot": slot_id, "file": cache_name, "server": server_url, "time": time.time()})
    return True


def restore_slot(server_url, slot_id, cache_name, cache_dir, model=None):
    """Restore slot KV cache by POSTing to llama.cpp server."""
    _log('info', f"restore_slot start: slot={slot_id} cache={cache_name} server={server_url}")
    if not _check_meta_exists(cache_dir):
        _log('info', f"restore_slot skipped: no valid meta file for cache_dir={cache_dir}")
        return False

    payload = {"filename": cache_name, "model": model} if model else {"filename": cache_name}

    try:
        url = f"{server_url}/slots/{slot_id}?action=restore"
        _log('debug', f"restore_slot POST to {url}")
        resp = httpx.post(url, json=payload, timeout=30)
        resp.raise_for_status()
        _log('info', f"restore_slot OK: slot={slot_id} cache={cache_name}")
        _update_meta(cache_dir, {"action": "restore", "slot": slot_id, "file": cache_name, "time": time.time()})
        return True
    except httpx.HTTPError as e:
        _log('warning', f"restore_slot FAILED: {e}")
        return False


def _check_meta_available(cache_dir, server_url=None):
    """Check if meta marks slots API as unavailable for this server.
    
    Returns True if compatible or unknown, False if server is known incompatible.
    """
    meta = Path(cache_dir) / ".slot-cache-meta.jsonl"
    if not meta.exists():
        _log('debug', f"_check_meta_available: no meta file yet at {meta}")
        return True
    
    try:
        with open(meta) as f:
            lines = f.readlines()
            if lines:
                last = json.loads(lines[-1])
                if last.get("action") == "unavailable":
                    _log('debug', f"_check_meta_available: last entry is 'unavailable'")
                    if server_url and last.get("server") == server_url:
                        _log('warning', f"_check_meta_available: API unavailable for server={server_url}")
                        return False
                    _log('debug', f"_check_meta_available: 'unavailable' is for different server, OK for {server_url}")
                    return True
        return True
    except (json.JSONDecodeError, IOError, KeyError) as e:
        _log('warning', f"_check_meta_available: error reading meta: {e}")
        return True


def check_cache(cache_name, cache_dir, server_url=None):
    """Check if slot cache is available.
    
    Returns True if local meta exists, server is compatible, and cache is recent (< 24h).
    Returns False if server is known incompatible (no slots API).
    Returns None if no cache but server is compatible (API may work, just no cache yet).
    """
    _log('debug', f"check_cache: cache_name={cache_name} cache_dir={cache_dir} server={server_url}")
    if not _check_meta_available(cache_dir, server_url):
        _log('info', f"check_cache: server incompatible for {cache_name}")
        return False
    if not _check_meta_for_cache(cache_name, cache_dir):
        _log('info', f"check_cache: no cache '{cache_name}' yet (normal for new session)")
        return None
    _log('debug', f"check_cache: cache OK for {cache_name}")
    return True


def verify_api(server_url, slot_id, cache_dir, model=None):
    """Verify that the /slots API is supported by the server.
    
    Uses GET /slots?model=<model> which returns slot count/info.
    Records incompatibility in meta if the API is not available.
    """
    _log('info', f"verify_api: server={server_url}")
    params = {"model": model} if model else {}
    url = f"{server_url}/slots"
    try:
        _log('debug', f"verify_api GET {url}")
        resp = httpx.get(url, params=params, timeout=30)
        if resp.status_code == 404:
            _log('warning', f"verify_api FAILED: 404 - slots API not supported on {server_url}")
            _update_meta(cache_dir, {
                "action": "unavailable",
                "server": server_url,
                "reason": "slots API not supported",
                "time": time.time()
            })
            return False
        resp.raise_for_status()
        _log('info', f"verify_api OK: slots API supported on {server_url}")
        return True
    except httpx.HTTPStatusError as e:
        if e.response.status_code == 404:
            _log('warning', f"verify_api FAILED: 404 - slots API not supported on {server_url}")
            _update_meta(cache_dir, {
                "action": "unavailable",
                "server": server_url,
                "reason": "slots API not supported",
                "time": time.time()
            })
            return False
        _log('error', f"verify_api HTTP error: {e.response.status_code} - {e.response.text}")
        return False
    except httpx.HTTPError as e:
        _log('error', f"verify_api error: {e}")
        return False


def _check_meta_exists(cache_dir):
    """Check if meta file exists and is not empty."""
    meta = Path(cache_dir) / ".slot-cache-meta.jsonl"
    if not meta.exists():
        _log('debug', f"_check_meta_exists: meta not found at {meta}")
        return False
    try:
        size = meta.stat().st_size
        if size == 0:
            _log('debug', f"_check_meta_exists: meta file is empty")
            return False
        with open(meta) as f:
            lines = f.readlines()
            if lines:
                last = json.loads(lines[-1])
                # Skip entries marked as unavailable for this server
                if last.get("action") == "unavailable" and "server" in last:
                    _log('debug', f"_check_meta_exists: meta marked as unavailable")
                    return False
                age = time.time() - last.get("time", 0)
                if age < 86400:
                    _log('debug', f"_check_meta_exists: meta OK, age={age:.0f}s")
                    return True
                else:
                    _log('info', f"_check_meta_exists: meta expired, age={age:.0f}s")
                    return False
    except (json.JSONDecodeError, IOError, KeyError) as e:
        _log('warning', f"_check_meta_exists: error reading meta: {e}")
        return False
    _log('debug', f"_check_meta_exists: no lines in meta")
    return False


def _check_meta_for_cache(cache_name, cache_dir):
    """Check if a specific cache name exists in meta and is recent (< 24h).
    
    Returns True if the cache exists and is valid, False otherwise.
    """
    meta = Path(cache_dir) / ".slot-cache-meta.jsonl"
    if not meta.exists():
        _log('debug', f"_check_meta_for_cache: meta not found at {meta}")
        return False
    try:
        size = meta.stat().st_size
        if size == 0:
            _log('debug', f"_check_meta_for_cache: meta file is empty")
            return False
        with open(meta) as f:
            lines = f.readlines()
            cache_file = f"{cache_name}.kv"
            for line in lines:
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                except json.JSONDecodeError:
                    continue
                # Skip unavailable entries
                if entry.get("action") == "unavailable":
                    continue
                # Check if this entry matches our cache name
                if entry.get("file") == cache_file or entry.get("file") == cache_name:
                    age = time.time() - entry.get("time", 0)
                    if age < 86400:
                        _log('debug', f"_check_meta_for_cache: cache '{cache_name}' found, age={age:.0f}s")
                        return True
                    else:
                        _log('info', f"_check_meta_for_cache: cache '{cache_name}' expired, age={age:.0f}s")
                        return False
        _log('info', f"_check_meta_for_cache: cache '{cache_name}' not found in meta")
        return False
    except (json.JSONDecodeError, IOError, KeyError) as e:
        _log('warning', f"_check_meta_for_cache: error reading meta: {e}")
        return False


def _update_meta(cache_dir, entry):
    """Append metadata entry to meta file."""
    _log('debug', f"_update_meta: action={entry.get('action')} file={entry.get('file')}")
    try:
        Path(cache_dir).mkdir(parents=True, exist_ok=True)
        meta = Path(cache_dir) / ".slot-cache-meta.jsonl"
        # Ensure file ends with newline before appending
        content = meta.read_text() if meta.exists() else ""
        if content and not content.endswith("\n"):
            with open(meta, "a") as f:
                f.write("\n")
        with open(meta, "a") as f:
            f.write(json.dumps(entry) + "\n")
    except IOError as e:
        _log('error', f"_update_meta: failed to write meta: {e}")


def list_caches(cache_dir, model=None, session_id=None):
    """List all cached .kv files with their metadata.
    
    Returns a list of dicts with: filename, size_bytes, last_modified, slot_id, session_id, action, time
    """
    _log('debug', f"list_caches: cache_dir={cache_dir} model={model}")
    meta = Path(cache_dir) / ".slot-cache-meta.jsonl"
    if not meta.exists():
        return []

    results = []
    try:
        with open(meta) as f:
            lines = f.readlines()
            for line in lines:
                line = line.strip()
                if not line:
                    continue
                try:
                    entry = json.loads(line)
                except json.JSONDecodeError:
                    continue
                
                # Filter by model if provided
                if model and entry.get("model") != model:
                    continue
                
                # Filter by session_id if provided
                if session_id and entry.get("session_id") != session_id:
                    continue
                
                # Skip incompatible entries
                if entry.get("action") == "unavailable":
                    continue
                
                cache_file = entry.get("file", "")
                if cache_file:
                    kv_path = Path(cache_dir) / cache_file
                    if kv_path.exists():
                        stat = kv_path.stat()
                        entry["size_bytes"] = stat.st_size
                        entry["filename"] = cache_file
                        entry["cache_file"] = str(kv_path.absolute())
                    else:
                        entry["size_bytes"] = 0
                        entry["filename"] = cache_file
                        entry["cache_file"] = str(kv_path.absolute())
                    entry["kv_file_exists"] = kv_path.exists()
                    results.append(entry)
                else:
                    results.append(entry)
    except IOError:
        return []
    
    _log('debug', f"list_caches: found {len(results)} cache(s)")
    return results


def delete_cache(cache_dir, cache_name):
    """Delete a specific cached slot by cache name.
    
    Removes the .kv file and the meta entry.
    Returns True if deleted, False if not found.
    """
    _log('info', f"delete_cache: cache_name={cache_name} cache_dir={cache_dir}")
    cache_file = f"{cache_name}.kv"
    kv_path = Path(cache_dir) / cache_file
    meta = Path(cache_dir) / ".slot-cache-meta.jsonl"
    
    deleted = False
    
    # Remove .kv file
    if kv_path.exists():
        kv_path.unlink()
        deleted = True
        _log('info', f"delete_cache: removed .kv file {kv_path}")
    
    # Update meta with deletion record
    if meta.exists():
        try:
            with open(meta) as f:
                lines = f.readlines()
            
            new_lines = []
            for line in lines:
                line = line.strip()
                if not line:
                    new_lines.append(line)
                    continue
                try:
                    entry = json.loads(line)
                    # Match either with or without .kv extension
                    file_field = entry.get("file", "")
                    if file_field == cache_file or file_field == cache_name or file_field == f"{cache_name}.kv":
                        entry["deleted"] = True
                        entry["delete_time"] = time.time()
                        new_lines.append(json.dumps(entry) + "\n")
                        _log('info', f"delete_cache: marked meta entry as deleted for {file_field}")
                        deleted = True
                    else:
                        new_lines.append(line)
                except json.JSONDecodeError:
                    new_lines.append(line)
            
            if new_lines:
                with open(meta, "w") as f:
                    f.writelines(new_lines)
            else:
                if meta.exists():
                    meta.unlink()
        except IOError as e:
            _log('error', f"delete_cache: failed to update meta: {e}")
    
    return deleted
