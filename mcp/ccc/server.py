import asyncio
from mcp.server.stdio import stdio_server
from fastmcp import FastMCP

mcp = FastMCP("ccc")


@mcp.tool()
async def ccc_init_project():
    """Initialize a new project for CocoIndex codebase indexing"""
    cmd = ["ccc", "init"]
    return await _run_cmd(cmd)


@mcp.tool()
async def ccc_index_codebase():
    """Index the source code to enable semantic search"""
    cmd = ["ccc", "index"]
    return await _run_cmd(cmd)


@mcp.tool()
async def ccc_semantic_search(query: str):
    """Search the codebase using semantic similarity (best for finding code by meaning)"""
    cmd = ["ccc", "search", query]
    return await _run_cmd(cmd)


@mcp.tool()
async def ccc_get_index_status():
    """Get the current status and statistics of the codebase index"""
    cmd = ["ccc", "status"]
    return await _run_cmd(cmd)


@mcp.tool()
async def ccc_reset_index(force: bool = False):
    """Reset the codebase index and all its databases"""
    cmd = ["ccc", "reset"]
    if force:
        cmd.append("-f")
    return await _run_cmd(cmd)


@mcp.tool()
async def ccc_check_system_health():
    """Check the health and diagnostic status of the CocoIndex system"""
    cmd = ["ccc", "doctor"]
    return await _run_cmd(cmd)


@mcp.tool()
async def ccc_restart_daemon():
    """Restart the CocoIndex daemon"""
    cmd = ["ccc", "daemon", "restart"]
    return await _run_cmd(cmd)


async def _run_cmd(cmd):
    process = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    stdout, stderr = await process.communicate()

    result = stdout.decode().strip()
    if stderr.decode().strip():
        result += "\n" + stderr.decode().strip()

    return result


if __name__ == "__main__":
    mcp.run()
