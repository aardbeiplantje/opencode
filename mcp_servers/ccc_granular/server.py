import asyncio
import subprocess
import sys
from mcp.server.models import InitializationOptions
import mcp.types as types
from mcp.server import NotificationOptions, Server
from mcp.server.stdio import stdio_server

server = Server("ccc-granular")

@server.list_tools()
async def handle_list_tools() -> list[types.Tool]:
    return [
        types.Tool(
            name="ccc_init_project",
            description="Initialize a new project for CocoIndex codebase indexing",
            inputSchema={
                "type": "object",
                "properties": {},
            },
        ),
        types.Tool(
            name="ccc_index_codebase",
            description="Index the source code to enable semantic search",
            inputSchema={
                "type": "object",
                "properties": {},
            },
        ),
        types.Tool(
            name="ccc_semantic_search",
            description="Search the codebase using semantic similarity (best for finding code by meaning)",
            inputSchema={
                "type": "object",
                "properties": {
                    "query": {"type": "string", "description": "The semantic search query"},
                },
                "required": ["query"],
            },
        ),
        types.Tool(
            name="ccc_get_index_status",
            description="Get the current status and statistics of the codebase index",
            inputSchema={
                "type": "object",
                "properties": {},
            },
        ),
        types.Tool(
            name="ccc_reset_index",
            description="Reset the codebase index and all its databases",
            inputSchema={
                "type": "object",
                "properties": {
                    "force": {"type": "boolean", "description": "Force the reset"},
                },
            },
        ),
        types.Tool(
            name="ccc_check_system_health",
            description="Check the health and diagnostic status of the CocoIndex system",
            inputSchema={
                "type": "object",
                "properties": {},
            },
        ),
        types.Tool(
            name="ccc_restart_daemon",
            description="Restart the CocoIndex daemon",
            inputSchema={
                "type": "object",
                "properties": {},
            },
        ),
    ]

@server.call_tool()
async def handle_call_tool(
    name: str, arguments: dict | None
) -> list[types.TextContent | types.ImageContent | types.EmbeddedResource]:
    if name == "ccc_init_project":
        cmd = ["ccc", "init"]
    elif name == "ccc_index_codebase":
        cmd = ["ccc", "index"]
    elif name == "ccc_semantic_search":
        if not arguments or "query" not in arguments:
            raise ValueError("Missing 'query' argument")
        cmd = ["ccc", "search", arguments["query"]]
    elif name == "ccc_get_index_status":
        cmd = ["ccc", "status"]
    elif name == "ccc_reset_index":
        cmd = ["ccc", "reset"]
        if arguments and arguments.get("force"):
            cmd.append("-f")
    elif name == "ccc_check_system_health":
        cmd = ["ccc", "doctor"]
    elif name == "ccc_restart_daemon":
        cmd = ["ccc", "daemon", "restart"]
    else:
        raise ValueError(f"Unknown tool: {name}")

    process = await asyncio.create_subprocess_exec(
        *cmd,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.PIPE,
    )
    stdout, stderr = await process.communicate()

    result = stdout.decode().strip()
    if stderr.decode().strip():
        result += "\n" + stderr.decode().strip()

    return [types.TextContent(type="text", text=result)]

async def main():
    async with stdio_server() as (read_stream, write_stream):
        await server.run(
            read_stream,
            write_stream,
            InitializationOptions(
                server_name="ccc-granular",
                server_version="0.1.0",
                capabilities=server.get_capabilities(
                    notification_options=NotificationOptions(),
                    experimental_capabilities={},
                ),
            ),
        )

if __name__ == "__main__":
    asyncio.run(main())
