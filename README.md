# terraform-aws-agentcore-dcr

Terraform module that lets MCP clients such as Claude (web, Desktop, Code) and Cursor connect to an
**AWS AgentCore Gateway** that uses **Amazon Cognito** for logins, **without creating login clients by hand**.

> **Status: work in progress (v0.1).** Written during a FivexL summer practice project (October to November 2026).
> The Terraform version was tested with Claude Code and Cursor. Claude web and Desktop were tested on an earlier
> CloudFormation version of the same design and still have to be re-tested on this one. See "Known limitations".

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
- Optional: sign-in providers in the user pool (Google, any OpenID Connect provider, SAML), a Lambda that only lets in
  people with an email in approved domains, and `modules/github-oidc-wrapper`, which adds **GitHub login** by running a
  community wrapper that makes GitHub look like an OpenID Connect provider (experimental).

## How a connection works
1. The client calls the Gateway without a token and gets `401` with a pointer to its metadata.
2. It reads the login description and finds `registration_endpoint`.
3. It calls `/register`; a Cognito client is created and allowed on the Gateway.
4. It sends the user to Cognito's login page (authorization code flow with PKCE).
5. It exchanges the code for a token and calls the Gateway with it; the Gateway checks the token and calls your Lambda.

## Usage
```hcl
module "agentcore_dcr" {
  source = "github.com/fivexl/terraform-aws-agentcore-dcr?ref=<tag or branch>"

  name_prefix           = "mcp"
  cognito_domain_prefix = "my-unique-prefix"
  tool_lambda_arn       = aws_lambda_function.tool.arn
}
```
**Start with the [getting started guide](docs/getting-started.md)**: deploy the example, connect Claude Code, check that it worked, clean up.
See [`examples/basic`](examples/basic) for the complete example. Add the `gateway_mcp_url` output as a custom
connector in Claude, or as an MCP server in Claude Code or Cursor.
By default people log in with Cognito users (username and password, for example created with `aws cognito-idp admin-create-user`).
For passwordless login set `include_cognito_users = false` and add a provider (see below).

## Documentation
- [docs/getting-started.md](docs/getting-started.md): deploy, connect, test, troubleshoot, clean up.
- [docs/identity-providers.md](docs/identity-providers.md): manual steps for Google, any OpenID Connect provider, IAM Identity Center, GitHub and SAML (Google Workspace), with what was tested.

## Differences from the project that inspired it
| Topic | stache-ai/agentcore-dcr | This module |
|---|---|---|
| Tooling | CloudFormation/SAM | Terraform |
| Client type | Always creates a client **with a secret** | Creates a **public client** when the caller asks for `token_endpoint_auth_method: none` |
| Redirect URIs | Not checked | Checked against `redirect_uri_allow_patterns` (an empty list refuses everything) |
| Logging | Logs the whole request | Does not log request bodies |
| Gateway update fails | Still answers success | Deletes the new client and answers an error; retries on conflicts |
| Throttling on `/register` | None | API throttling variables |
| Login description | Lists `token` as a response type | Lists `code` only; also lists `none` as a client login method |
| Custom scopes | Resource server must exist already | Created by the module |
| Login providers | Cognito users only | `oidc_providers` (Google, any OIDC), `saml_providers`, `identity_providers` for providers created elsewhere |
| Who may log in | Any user in the pool | Optional `allowed_email_domains` check |

## Useful inputs
| Input | What it does |
|---|---|
| `oidc_providers` / `oidc_client_secrets` | Create Google or generic OIDC sign-in providers in the user pool (secrets kept separate) |
| `saml_providers` | Create SAML providers (Google Workspace SAML app, IAM Identity Center) from a metadata file or address |
| `oidc_providers[*].endpoints` | Manual authorize, token, userinfo and key addresses, for providers whose discovery document does not work with Cognito (used for GitHub) |
| `include_cognito_users` | Set to `false` to remove username and password completely |
| `allowed_email_domains` | Only people with an email in these domains get in (checked at sign-up and at every token issue). Google and GitHub users must have a verified email; users of a provider listed in `saml_providers` are trusted, because SAML never reports `email_verified` |
| `redirect_uri_allow_patterns` | Which client callback addresses may register |
| `identity_providers` | Names of providers created elsewhere that clients may use |

## Tests
```
python -m unittest discover -s tests -v
```
They cover the email check and the callback address check of the two Lambda functions (no AWS access needed).
Install the checks that run before each commit with `pip install pre-commit && pre-commit install`.

## Known limitations
- **`/register` is open to the internet by design.** Keep the redirect allow list tight and delete the stack when you are not testing.
- **Issuer mismatch.** The login description is served from the API's address but names Cognito as the issuer.
  Strict clients (the MCP Inspector) reject this; Claude Code and Cursor accepted it in testing.
  A complete fix probably needs a proxy in front of the Gateway.
- Every connection attempt registers a new client; old clients are not cleaned up yet.
- A client that asks for no valid scope gets all scopes the module knows (including `write`). Consider narrowing this before real use.
- A token that was already issued stays valid until it expires, also after a person leaves the company.
- Client secrets (Google, GitHub) end up in the Terraform state, and the GitHub secret also in the Lambda settings. Use an encrypted remote state and never commit state files.
- Tested login providers: Cognito users, Google (OIDC), GitHub (through a community wrapper, experimental: no organisation check, signing key bundled in the code)
  and SAML with a Google Workspace app and with an IAM Identity Center customer managed application.

## Credit and licence
Inspired by [stache-ai/agentcore-dcr](https://github.com/stache-ai/agentcore-dcr) (MIT), see [NOTICE](NOTICE).
Licence for this module: Apache License 2.0, see [LICENSE](LICENSE).
