# Getting started

This guide takes you from nothing to a working connection: deploy the example, connect Claude Code, check that it worked, and clean up.
It uses the example in `examples/basic` (a Gateway with one tiny `hello` tool). Everything runs in one AWS account and costs very little (Lambda, API Gateway and Cognito are pay per use), but delete it when you are done.

## What you need
- An AWS account and credentials that can create Cognito, API Gateway, Lambda, IAM and AgentCore resources, in a region where AgentCore Gateway is available (the example uses `us-east-1`).
- Terraform 1.5 or newer and the AWS provider 6.x (tested with 6.71).
- Claude Code (`claude` on the command line) or Cursor.
- A unique name for the Cognito login page address (see step 1).

## 1. Deploy the example
```
cd examples/basic
terraform init
terraform apply -var 'cognito_domain_prefix=<your-unique-prefix>'
```
The prefix becomes `<prefix>.auth.<region>.amazoncognito.com`. It must be unique in the region and must not contain `aws`, `amazon` or `cognito`.
The apply creates the user pool, the registration API and Lambda, the AgentCore Gateway and the `hello` tool. It takes a few minutes.

Note the outputs:
```
terraform output gateway_mcp_url     # the address to connect to
terraform output dcr_endpoint        # the registration endpoint (POST /register)
terraform output user_pool_id
```

## 2. Create someone who can log in
The simplest way is a Cognito user (the default). Replace the placeholders:
```
aws cognito-idp admin-create-user --user-pool-id <user_pool_id> --username <name> \
  --user-attributes Name=email,Value=<email> Name=email_verified,Value=true --message-action SUPPRESS
aws cognito-idp admin-set-user-password --user-pool-id <user_pool_id> --username <name> \
  --password '<a strong password>' --permanent
```
For passwordless login (Google, GitHub or SAML) set `include_cognito_users = false` and add a provider instead; see [identity-providers.md](identity-providers.md).
To let in only people from your company add `allowed_email_domains = ["example.com"]`.

## 3. Connect Claude Code
```
claude mcp add --transport http --scope user my-gateway <gateway_mcp_url>
claude
```
In Claude Code type `/mcp`, choose `my-gateway` and authenticate. What happens:
1. Claude Code calls the Gateway, gets `401`, and reads the login description.
2. It registers itself at `/register` (a new Cognito client is created and allowed on the Gateway).
3. The browser opens the Cognito login page. Log in.
4. `/mcp` now shows the server as connected with one tool, `hello`.

Try it by asking: *Use the hello tool to greet me.*

`--scope user` makes the server available in every folder. Without it the entry belongs only to the folder you ran the command in.

**Cursor:** add the server in Cursor's `mcp.json` with the address, for example `{"mcpServers": {"my-gateway": {"url": "<gateway_mcp_url>"}}}`, then log in when Cursor asks.
**Claude web and Desktop:** add a custom connector with the same address (needs permission to add custom connectors).

## 4. Check that it worked
- A new app client appears in the Cognito console (User pool, App clients) for each connection.
- The registration Lambda log (`/aws/lambda/<name_prefix>-dcr`) says `Registered client ...`.
- If you set `allowed_email_domains`, the check Lambda log (`/aws/lambda/<name_prefix>-signup-domain-check`) says `Allowed: ...` or `Rejected: ...` with the reason.
- Without a token the Gateway must answer `401`; a registration with an unknown callback address must be refused:
```
curl -s -i -X POST <gateway_mcp_url> -H 'Content-Type: application/json' -d '{}'
curl -s -X POST <dcr_endpoint> -H 'Content-Type: application/json' \
  -d '{"client_name":"test","redirect_uris":["https://evil.example.com/cb"],"token_endpoint_auth_method":"none"}'
```

## Troubleshooting
| What you see | Usual cause |
|---|---|
| The login page is skipped and Claude Code says it is connected at once | Cognito remembers the browser session. Use a private window, or delete the site data for `amazoncognito.com` |
| "localhost refused to connect" after login | Claude Code closed its local listener after an earlier failed try. Close old tabs and make one clean attempt |
| The login page has no button for a provider | The client was registered before the provider was added. Remove the server and add it again so it registers fresh |
| `invalid_redirect_uri` from `/register` | The client's callback address is not in `redirect_uri_allow_patterns`. The Lambda log shows the rejected address |
| "Sign-in is limited to approved email domains" or "no email address" | The email check refused the login. For SAML the attribute name in the provider must match the module setting exactly (see identity-providers.md) |
| `Invalid index` or a plan with far too many additions | The environment variable with a client secret is missing in this terminal. Set it and plan again; never apply a plan that came with an error |
| Provider name error for Google | The key in `oidc_providers` must be exactly `Google` |

## Clean up
```
cd examples/basic
terraform destroy -var 'cognito_domain_prefix=<your-unique-prefix>'
```
Set the same environment variables first if you used providers with secrets. Also delete the apps you created at the providers (a Google OAuth client, a GitHub OAuth App, a SAML app) and never commit the Terraform state files, which contain secrets.

## What was tested
| Part | Result |
|---|---|
| Registration, login with Cognito users | Works with Claude Code and Cursor |
| Google (OIDC), passwordless, company-email check | Works with Claude Code |
| GitHub through the wrapper | Works with Claude Code (experimental) |
| SAML with a Google Workspace app | Works with Claude Code |
| Claude web and Desktop | Worked on the first version of this design; not re-tested on this module |
| IAM Identity Center | Not tried yet |
