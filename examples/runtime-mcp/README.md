# Example: MCP server in AgentCore Runtime behind the DCR gateway

> **Status: draft.** The Terraform validates and the server was tested locally, but this example has **not been deployed yet**.
> The points marked "unverified" below are the things to check at the first apply.

An MCP server is hosted in **AgentCore Runtime** (each session runs in its own isolated microVM, and the newer Runtime
generation scales to zero and starts in about 2 seconds). People still log in through the gateway of this module (Cognito,
dynamic client registration, optional email and group checks). The gateway then calls the MCP server in Runtime.

```
Claude Code  ->  Gateway (login, DCR)  ->  MCP server in Runtime (isolated session per user session)
```

## How the gateway reaches the Runtime
The Runtime has **no JWT authorizer**, so it only accepts calls signed with IAM (SigV4). The gateway signs them with its own role,
which gets the permission `bedrock-agentcore:InvokeAgentRuntime` on this one Runtime. Nobody else can call it.

Why not let the Runtime check the user's token itself: its JWT authorizer wants `allowed_clients` or an audience, and clients that
register through DCR have client IDs nobody knows in advance (Cognito access tokens also have no `aud` claim). `allowed_scopes` could
work together with `group_scopes` (roles by group), but that is not tried yet.

## Try it
```bash
cd examples/runtime-mcp
python build.py                      # builds .build/server.zip (needs Python and uv, no Docker)
terraform init
terraform apply -var cognito_domain_prefix=<unique-prefix>
```
Then add the `gateway_mcp_url` output as an MCP server in Claude Code, log in, and list the tools: `hello_runtime` should appear
next to the Lambda tool. (Creating the gateway target makes the gateway ask the server for its tools once. If you change the
server's tools later, synchronize the target.)

Clean up with `terraform destroy`.

## Cost
Runtime bills while a session runs and scales to zero when idle; the S3 bucket holds a 10 MB file. Destroy it when you are done testing.

## Unverified at the first apply
- The values `platform_version = "V2"` and `runtime = "PYTHON_3_13"` (the provider does not list the allowed values).
- That the gateway can call a Runtime-hosted server this way (IAM outbound authorization to Runtime is documented for MCP server targets).
- The `/ping` health route and stateless mode as AWS documents them; the server runs locally and answers `initialize` and a tool call.
- Whether the MCP protocol version the gateway uses is accepted by the Runtime.

## Next steps
- Pass the **user's identity** to the server (so it can see who calls): Cognito's new OAuth token exchange with the gateway's
  on-behalf-of option, instead of the gateway's own IAM role.
- A reusable `modules/mcp-runtime` once the shape is settled.
