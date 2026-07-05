"""Construct the FastMCP server and mount it on the FastAPI app.

The MCP endpoint lives at ``/mcp`` (Streamable HTTP transport). MCP
clients (Claude Code, Cursor, Windsurf, VS Code MCP extensions) connect
directly via URL, sending ``Authorization: Bearer <VOICEBOX_API_KEY>``.
"""

from __future__ import annotations

import logging
from contextlib import AsyncExitStack, asynccontextmanager

from fastmcp import FastMCP

from .tools import register_tools


logger = logging.getLogger(__name__)


def build_mcp_server() -> FastMCP:
    """Create the FastMCP instance with Voicebox tools registered."""
    mcp = FastMCP(
        name="voicebox",
        instructions=(
            "Voicebox is a local voice I/O layer. Use `voicebox.speak` to "
            "play text in a voice profile, `voicebox.transcribe` for "
            "audio→text, and the `list_*` tools to discover profiles and "
            "captures."
        ),
    )
    register_tools(mcp)
    return mcp


def compose_lifespan(*lifespans):
    """Combine multiple async context managers into a single FastAPI lifespan.

    Used by ``create_app`` to run the existing Voicebox startup/shutdown
    together with FastMCP's session manager (which MUST run in the
    ASGI lifespan for Streamable HTTP to work).
    """

    @asynccontextmanager
    async def _combined(app):
        async with AsyncExitStack() as stack:
            for cm_factory in lifespans:
                cm = cm_factory(app) if callable(cm_factory) else cm_factory
                await stack.enter_async_context(cm)
            yield

    return _combined
