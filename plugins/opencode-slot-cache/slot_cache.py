#!/usr/bin/env python3
"""
llama.cpp slot cache manager CLI.

Wraps slot_cache_lib for command-line usage and MCP server integration.
"""
import sys
import argparse
import json
import logging
import os
import time
import httpx
from pathlib import Path
from slot_cache_lib import (
    save_slot, restore_slot, check_cache, verify_api,
    list_caches, delete_cache, _check_meta_available, _check_meta_exists,
    set_logger
)


def setup_logging():
    """Set up logging to file only."""
    logger = logging.getLogger('slot-cache')
    logger.setLevel(logging.DEBUG)
    
    # File handler
    log_dir = Path(os.environ.get('SLOT_CACHE_LOG_DIR', str(Path(__file__).parent)))
    log_dir.mkdir(parents=True, exist_ok=True)
    log_file = log_dir / 'slot_cache_cli.log'
    
    fh = logging.FileHandler(str(log_file), mode='a')
    fh.setLevel(logging.DEBUG)
    fh.setFormatter(logging.Formatter('%(asctime)s [slot-cache] [%(levelname)s] %(message)s', datefmt='%Y-%m-%dT%H:%M:%S'))
    logger.addHandler(fh)
    
    return logger


def main():
    parser = argparse.ArgumentParser(description="llama.cpp slot cache manager")
    subparsers = parser.add_subparsers(dest="command", required=True)

    # save
    save_parser = subparsers.add_parser("save", help="Save slot KV cache to remote server")
    save_parser.add_argument("server_url", help="llama.cpp server base URL")
    save_parser.add_argument("slot_id", type=int, help="Slot ID to manage")
    save_parser.add_argument("cache_name", help="Cache name")
    save_parser.add_argument("cache_dir", help="Directory for cache metadata files")
    save_parser.add_argument("--model", default=None, help="Model name")

    # restore
    restore_parser = subparsers.add_parser("restore", help="Restore slot KV cache from remote server")
    restore_parser.add_argument("server_url", help="llama.cpp server base URL")
    restore_parser.add_argument("slot_id", type=int, help="Slot ID to manage")
    restore_parser.add_argument("cache_name", help="Cache name")
    restore_parser.add_argument("cache_dir", help="Directory for cache metadata files")
    restore_parser.add_argument("--model", default=None, help="Model name")

    # check
    check_parser = subparsers.add_parser("check", help="Check if a valid cache file exists")
    check_parser.add_argument("server_url", help="llama.cpp server base URL")
    check_parser.add_argument("slot_id", type=int, help="Slot ID")
    check_parser.add_argument("cache_name", help="Cache name")
    check_parser.add_argument("cache_dir", help="Directory for cache metadata files")
    check_parser.add_argument("--model", default=None, help="Model name")

    # verify
    verify_parser = subparsers.add_parser("verify", help="Verify slots API is supported")
    verify_parser.add_argument("server_url", help="llama.cpp server base URL")
    verify_parser.add_argument("slot_id", type=int, help="Slot ID")
    verify_parser.add_argument("cache_name", help="Cache name")
    verify_parser.add_argument("cache_dir", help="Directory for cache metadata files")
    verify_parser.add_argument("--model", default=None, help="Model name")

    # list
    list_parser = subparsers.add_parser("list", help="List all cached slots")
    list_parser.add_argument("cache_dir", help="Directory for cache metadata files")
    list_parser.add_argument("--model", default=None, help="Model name")
    list_parser.add_argument("--session-id", default=None, help="Filter by session ID")

    # delete
    delete_parser = subparsers.add_parser("delete", help="Delete a cached slot")
    delete_parser.add_argument("cache_dir", help="Directory for cache metadata files")
    delete_parser.add_argument("cache_name", help="Cache name to delete")

    args = parser.parse_args()
    logger = setup_logging()
    
    # Set the shared logger in slot_cache_lib
    set_logger(logger)

    try:
        if args.command == "save":
            logger.info(f"save: server={args.server_url} slot_id={args.slot_id} cache_name={args.cache_name} cache_dir={args.cache_dir} model={args.model}")
            result = save_slot(args.server_url, args.slot_id, args.cache_name, args.cache_dir, model=args.model)
            if result:
                logger.info(f"save: OK (slot {args.slot_id}, cache '{args.cache_name}')")
            else:
                logger.warning(f"save: FAILED (slot {args.slot_id}, cache '{args.cache_name}')")
            sys.exit(0 if result else 1)

        elif args.command == "restore":
            logger.info(f"restore: server={args.server_url} slot_id={args.slot_id} cache_name={args.cache_name} cache_dir={args.cache_dir} model={args.model}")
            result = restore_slot(args.server_url, args.slot_id, args.cache_name, args.cache_dir, model=args.model)
            if result:
                logger.info(f"restore: OK (slot {args.slot_id}, cache '{args.cache_name}')")
            else:
                logger.warning(f"restore: FAILED (slot {args.slot_id}, cache '{args.cache_name}')")
            sys.exit(0 if result else 1)

        elif args.command == "check":
            logger.info(f"check: server={args.server_url} slot_id={args.slot_id} cache_name={args.cache_name} cache_dir={args.cache_dir} model={args.model}")
            result = check_cache(args.cache_name, args.cache_dir, server_url=args.server_url)
            if result is True:
                logger.info(f"check: cache exists for '{args.cache_name}'")
                sys.exit(0)
            elif result is False:
                logger.warning(f"check: slots API unavailable for '{args.cache_name}'")
                sys.exit(2)
            else:
                logger.info(f"check: no cache found for '{args.cache_name}' (normal for new session)")
                sys.exit(1)

        elif args.command == "verify":
            logger.info(f"verify: server={args.server_url} slot_id={args.slot_id} cache_name={args.cache_name} cache_dir={args.cache_dir} model={args.model}")
            if verify_api(args.server_url, args.slot_id, args.cache_dir, model=args.model):
                logger.info(f"verify: slots API supported on {args.server_url}")
                sys.exit(0)
            else:
                logger.warning(f"verify: slots API NOT supported on {args.server_url}")
                sys.exit(1)

        elif args.command == "list":
            logger.info(f"list: cache_dir={args.cache_dir} model={args.model} session_id={args.session_id}")
            caches = list_caches(args.cache_dir, model=args.model, session_id=args.session_id)
            print(json.dumps(caches, indent=2))
            logger.info(f"list: found {len(caches)} cache(s)")
            sys.exit(0)

        elif args.command == "delete":
            logger.info(f"delete: cache_dir={args.cache_dir} cache_name={args.cache_name}")
            result = delete_cache(args.cache_dir, args.cache_name)
            if result:
                logger.info(f"delete: OK (removed '{args.cache_name}')")
            else:
                logger.warning(f"delete: NOT FOUND (cache '{args.cache_name}')")
            sys.exit(0 if result else 1)

    except httpx.HTTPStatusError as e:
        logger.error(f"HTTP error: {e.response.status_code} - {e.response.text}")
        sys.exit(1)
    except httpx.ConnectError as e:
        logger.error(f"Connection error: {e}")
        sys.exit(1)
    except Exception as e:
        logger.error(f"Error: {e}", exc_info=True)
        sys.exit(1)


if __name__ == "__main__":
    main()
