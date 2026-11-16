"""A tiny MCP server for AgentCore Runtime.

AgentCore Runtime expects an MCP server at 0.0.0.0:8000/mcp in stateless mode, and a /ping health check.
"""

from mcp.server.fastmcp import FastMCP
from starlette.requests import Request
from starlette.responses import JSONResponse

mcp = FastMCP("runtime-hello", host="0.0.0.0", port=8000, stateless_http=True)


@mcp.tool()
def hello_runtime(name: str = "world") -> str:
    """Greet someone from the MCP server that runs in AgentCore Runtime."""
    return f"hello, {name}, from AgentCore Runtime"


@mcp.custom_route("/ping", methods=["GET"])
async def ping(request: Request) -> JSONResponse:
    return JSONResponse({"status": "Healthy"})


if __name__ == "__main__":
    mcp.run(transport="streamable-http")
