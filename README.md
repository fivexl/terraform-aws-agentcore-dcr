# terraform-aws-agentcore-dcr

Terraform module that lets MCP clients such as Claude (web, Desktop, Code) and Cursor connect to an
**AWS AgentCore Gateway** that uses **Amazon Cognito** for logins, **without creating login clients by hand**.

> **Status: work in progress (v0.1).** Written during a FivexL summer practice project (October 2026).
> The design was tested by hand with Claude Code, Claude web and Claude Desktop; the Terraform version is
> being tested. See "Known limitations".

## The problem
MCP clients register themselves with the login system (dynamic client registration, RFC 7591) before they log in.
Cognito has no registration endpoint, so a client cannot sign itself up. This module adds one.

## What it creates
- A **Cognito user pool**, hosted login domain and resource server (custom scopes `<prefix>/read`, `<prefix>/write`),
  or it uses an existing pool.
- An **API Gateway** that serves the login description (`/.well-known/openid-configuration`, with a
  `registration_endpoint`) and `POST /register`.
- A **registration Lambda** that creates a Cognito app client per request and adds it to the Gateway's allowed clients.
- An **AgentCore Gateway** (custom JWT authorizer) and a **Lambda target** that exposes your tools.

Optional: `modules/github-oidc-wrapper` adds **GitHub login** by running a community wrapper that makes GitHub look like an
OpenID Connect provider (experimental, see `docs/identity-providers.md`, section 4).

## How a connection works
1. The client calls the Gateway without a token and gets `401` with a pointer to its metadata.
2. It reads the login description and finds `registration_endpoint`.
3. It calls `/register`; a Cognito client is created and allowed on the Gateway.
4. It sends the user to Cognito's login page (authorization code flow with PKCE).
5. It exchanges the code for a token and calls the Gateway with it; the Gateway checks the token and calls your Lambda.

## Usage
```hcl
module "agentcore_dcr" {
  source = "github.com/<owner>/terraform-aws-agentcore-dcr"

  name_prefix           = "mcp"
  cognito_domain_prefix = "my-unique-prefix"
  tool_lambda_arn       = aws_lambda_function.tool.arn
}
```
See [`examples/basic`](examples/basic) for a complete example. Add the `gateway_mcp_url` output as a custom
connector in Claude, or as an MCP server in Claude Code or Cursor. Create a Cognito user to log in with
(for example `aws cognito-idp admin-create-user`).

## Differences from the project that inspired it
| Topic | stache-ai/agentcore-dcr | This module |
|---|---|---|
| Tooling | CloudFormation/SAM | Terraform |
| Client type | Always creates a client **with a secret** | Creates a **public client** when the caller asks for `token_endpoint_auth_method: none` |
| Redirect URIs | Not checked | Checked against `redirect_uri_allow_patterns` |
| Logging | Logs the whole request | Does not log request bodies |
| Gateway update fails | Still answers success | Deletes the new client and answers an error; retries on conflicts |
| Throttling on `/register` | None | API throttling variables |
| Login description | Lists `token` as a response type | Lists `code` only; also lists `none` as a client login method |
| Custom scopes | Resource server must exist already | Created by the module |
| Login providers | Cognito users only | `identity_providers` input (Google, IAM Identity Center, ...) |

## Useful inputs
| Input | What it does |
|---|---|
| `oidc_providers` / `oidc_client_secrets` | Create Google or generic OIDC sign-in providers in the user pool (secrets kept separate) |
| `saml_providers` | Create SAML providers (Google Workspace SAML app, IAM Identity Center) from a metadata file or address |
| `oidc_providers[*].endpoints` | Manual authorize, token, userinfo and key addresses, for providers whose discovery document does not work with Cognito (used for GitHub) |
| `include_cognito_users` | Set to `false` to remove username and password completely |
| `allowed_email_domains` | Only people with a verified email in these domains get in (checked at sign-up and at every token issue) |
| `redirect_uri_allow_patterns` | Which client callback addresses may register |
| `identity_providers` | Names of providers created elsewhere that clients may use |

See [docs/identity-providers.md](docs/identity-providers.md) for the manual steps.

## Known limitations
- **`/register` is open to the internet by design.** Keep the redirect allow list tight and delete the stack when you are not testing.
- **Issuer mismatch.** The login description is served from the API's address but names Cognito as the issuer.
  Strict clients (the MCP Inspector) reject this; Claude Code, Claude web and Claude Desktop accepted it in testing.
  A complete fix probably needs a proxy in front of the Gateway.
- Every connection attempt registers a new client; old clients are not cleaned up yet.
- Tested login providers: Cognito users, Google (OIDC) and GitHub (through a community wrapper, see `docs/identity-providers.md`, section 4).
  SAML (`saml_providers`) works with a Google Workspace SAML app (tested 4 November 2026). IAM Identity Center is not tried yet.

## Credit and licence
Inspired by [stache-ai/agentcore-dcr](https://github.com/stache-ai/agentcore-dcr) (MIT), see [NOTICE](NOTICE).
Licence for this module: Apache License 2.0, see [LICENSE](LICENSE).


