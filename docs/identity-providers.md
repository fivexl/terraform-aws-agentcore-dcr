# Identity providers: manual steps

Cognito can let people sign in through another system (called federation) instead of a username and password.
Cognito then still issues its own tokens, so the AgentCore Gateway and the dynamic client registration do not change.
Only the login step does.

**This module supports OpenID Connect (OIDC) providers.** OIDC is the modern standard and is what is built and documented here.
This page lists the **manual steps** that must be done in the other system, with placeholder values.
Replace everything in `<angle brackets>` with your own values.

Values you will need from this module (see `terraform output`):

| Placeholder | Example | Where it comes from |
|---|---|---|
| `<cognito-domain-host>` | `my-prefix.auth.us-east-1.amazoncognito.com` | output `cognito_domain_host` |
| `<user-pool-id>` | `us-east-1_AbCdEfGhI` | output `user_pool_id` |
| `<provider-name>` | `Google` | the key in `oidc_providers`. For type Google it must be exactly `Google` (capital G); for type OIDC you choose it. |

The address every external provider must send people back to is always:

```
https://<cognito-domain-host>/oauth2/idpresponse
```

---

## 1. Google (Google Workspace or Google accounts)

### In Google
1. Sign in to the Google Cloud console (https://console.cloud.google.com/) and create or choose a project.
2. Open **Google Auth Platform**. On first use choose **Get started** and enter an app name (for example `MCP gateway login`), a support email and contact details.
3. **Audience:** choose **Internal** if everyone who may log in belongs to your Google Workspace organisation
   (this limits sign-in to your company domain). Choose **External** only if people outside the company must log in.
4. **Branding, Authorized domains:** add `amazoncognito.com` (or the root of your custom domain, for example `example.com`).
5. **Data access:** add the scopes `openid`, `.../auth/userinfo.email` and `.../auth/userinfo.profile`.
6. **Clients, Create client:** type **Web application**, name it (for example `cognito-mcp`).
   - Authorized JavaScript origins: `https://<cognito-domain-host>`
   - Authorized redirect URIs: `https://<cognito-domain-host>/oauth2/idpresponse`
7. Copy the **client ID** (looks like `123456789012-abc123.apps.googleusercontent.com`) and the **client secret**.
   Google shows the secret only once for new clients, so store it right away in a password manager.
8. Wait a few minutes. Changes to redirect addresses can take up to a few hours to apply.

### In Terraform
```hcl
module "agentcore_dcr" {
  source = "github.com/<owner>/terraform-aws-agentcore-dcr"
  # ... other inputs ...

  oidc_providers = {
    Google = {
      type      = "Google"
      client_id = "<client-id>.apps.googleusercontent.com"
    }
  }

  # Keep secrets out of git: set TF_VAR_oidc_client_secrets or use an untracked tfvars file.
  oidc_client_secrets = {
    Google = var.google_client_secret
  }

  # Optional: remove username and password completely.
  # include_cognito_users = false
}
```
Set the secret without writing it into a file that is committed, for example in PowerShell:
```
$env:TF_VAR_oidc_client_secrets = '{"Google":"<client-secret>"}'
```

### Check it
1. Register a client (Claude, Cursor, Claude Code) as usual and start the login.
2. The login page should show **Continue with Google**.
3. In the Cognito console, **User management, Users** now shows a federated user with the provider name in front of its ID.

### If something fails
| Message | Usual cause |
|---|---|
| `redirect_uri_mismatch` | The redirect URI in Google does not exactly match `https://<cognito-domain-host>/oauth2/idpresponse`. Check for typos, and wait a few minutes. |
| `origin_mismatch` | The JavaScript origin in Google is missing or has a path. It must be `https://<cognito-domain-host>` only. |
| No provider button on the login page | The provider is not enabled on the app client, or the login page version does not show it. Try `managed_login_version = 2`. |
| User details (email verified, name) do not update after a change | Cognito's login page keeps a session cookie, so the browser is not sent to Google again. Delete the cookie for `<cognito-domain-host>` (or use a private window) and sign in again. |
| Access blocked: app not verified | The audience is External and the user is not a listed test user. Use Internal, or add test users. |

---

## Restricting who can sign in (authorization)

Signing in with Google proves who a person is. It does not decide who is **allowed**. To allow only people from your company, use one or both of:

1. **Google "Internal" audience** (Google Workspace admin): only accounts of your Workspace organisation can use the app.
2. **`allowed_email_domains` in this module:** a small Cognito check rejects anyone whose **verified** email is not in one of the listed domains. It runs when a user is created **and every time tokens are issued or refreshed**, so existing users (and users created by hand, such as test users without an email) are checked too.

```hcl
allowed_email_domains = ["example.com"]
```

Notes:
- The check runs at sign-up **and** at every token issue or refresh (Cognito "pre sign-up" and "pre token generation" triggers). A user without a verified email in an approved domain gets no tokens.
- Users created by an administrator can be created, but they still need an approved email to receive tokens.
- It needs `create_user_pool = true`. For an existing pool, set up a pre sign-up trigger yourself.
- It relies on `email_verified`, which this module maps by default.
- To restrict by role as well, see section 6 (`allowed_groups`).

---

## 2. Any other OpenID Connect provider (Okta, Microsoft Entra, Auth0, ...)

### In the provider
1. Create an application of type **Web application / OIDC, authorization code flow**.
2. Sign-in redirect URI: `https://<cognito-domain-host>/oauth2/idpresponse`
3. Scopes: `openid`, `email`, `profile`.
4. Copy the **client ID**, the **client secret** and the **issuer address**
   (for example `https://<your-company>.okta.com` or `https://login.microsoftonline.com/<tenant-id>/v2.0`).
   The issuer must start with `https://` and must not end with `/`. Its `/.well-known/openid-configuration` must be reachable.

### In Terraform
```hcl
oidc_providers = {
  company-sso = {
    type      = "OIDC"
    client_id = "<client-id>"
    issuer    = "https://<issuer-address>"
  }
}
oidc_client_secrets = {
  company-sso = var.company_sso_client_secret
}
```

---

## 3. AWS IAM Identity Center (SAML only)

**Goal:** sign people in with their Identity Center account.

**Finding (AWS documentation, checked 29 October 2026): Identity Center cannot be used as an OIDC sign-in provider for Cognito.**
- Identity Center's OIDC and OAuth 2.0 support is for AWS's own clients: the AWS CLI, SDKs and AWS managed applications that
  retrieve credentials for AWS accounts. The documentation states that OAuth 2.0 grant flows "are only available through AWS managed applications".
- For your own application, Identity Center offers a **customer managed SAML 2.0 application** for sign-in. Its OAuth 2.0 option for
  customer managed applications is "trusted identity propagation" (passing a user's identity to AWS services), which is not a login for Cognito.

So for Identity Center the route is **SAML**, as described below. OIDC providers are Google and the providers in section 2.

Sources: IAM Identity Center User Guide, "Customer managed applications" and "Single sign-on access to SAML 2.0 and OAuth 2.0 applications";
IAM Identity Center OIDC API Reference, "Welcome".

### Identity Center with SAML (tested 9 November 2026)
**Result: works end to end with Claude Code.** A direct login ended on `localhost:33418/callback?code=...`, the user `IdentityCenter_<email>` was created
with the right email, and the check Lambda logged `Allowed: domain <domain> (trusted provider IdentityCenter)`. As with every SAML provider the user shows
"email verified: no" in Cognito (see section 5); that is expected.

The module creates the Cognito side with the `saml_providers` input (section 5). The steps in Identity Center (console, Region of your Identity Center instance):

1. **IAM Identity Center, Applications, Customer managed tab, Add application.** Choose **I have an application I want to set up**, then **SAML 2.0**, then Next.
   (The catalogue entry is called "Custom SAML 2.0 application".) Give it a display name, for example `MCP-Cognito-test`.
2. Under **IAM Identity Center metadata**, **Download** the **IAM Identity Center SAML metadata file**. It is public information, not a secret.
3. Under **Application metadata** choose **Manually type your metadata values** and enter:
   - **Application ACS URL:** `https://<cognito-domain-host>/saml2/idpresponse`
   - **Application SAML audience:** `urn:amazon:cognito:sp:<user-pool-id>`
4. Submit. On the application page choose **Actions, Edit attribute mappings**:
   - **Subject:** `${user:email}`, format **emailAddress**.
   - **Add new attribute mapping:** application attribute `email`, maps to `${user:email}`, format **unspecified**.
     The name must be exactly `email`, because that is what the module looks for by default (change it with `attribute_mapping` if you name it differently).
   - Save changes.
5. **Assign users and groups** (the application page, Assigned users, Assign users). Assignments are required, so only the people you assign can sign in.
   Prefer groups over single users, as AWS recommends. Nested groups are not supported.
6. In Terraform pass the downloaded file to the module:
   ```hcl
   saml_providers = {
     IdentityCenter = {
       metadata_file = file("idc-saml-metadata.xml")
     }
   }
   ```
   In the example this is the variable `idc_saml_metadata_path`. Apply, then test with the direct address from the "Status" part of section 5, using `identity_provider=IdentityCenter`.

Good to know:
- The application is separate from the existing applications (such as the AWS Management Console one). Nothing else is changed by adding it. It can be deleted later without effect on anyone.
- Identity Center can be managed from a delegated administrator account, not only from the management account.
- The people who sign in must have an email in `allowed_email_domains`, otherwise the check Lambda refuses them.
- Clicking the application's tile in the Identity Center portal starts the login on the Identity Center side and fails with a RelayState error, exactly like the Google tile (see section 5).
  The login has to start at Cognito, which is what MCP clients do.
- The SAML metadata (certificate) can be rotated by AWS; if logins suddenly fail, download the metadata again and apply.

---

## 4. GitHub (through a wrapper, tested 3 November 2026, experimental)

**Goal:** let people sign in with their GitHub account instead of Google.

**Finding: Cognito cannot use GitHub directly.** GitHub's login is plain OAuth 2.0. It has no OpenID Connect discovery
address and does not return an ID token, which Cognito's OIDC provider type needs. Cognito's documentation names other
providers (Salesforce, Okta, Microsoft Entra ID) as OIDC examples, not GitHub.

**Usual workaround: a small "wrapper" in front of GitHub** that looks like an OIDC provider to Cognito.
The community project [github-cognito-openid-wrapper](https://github.com/TimothyJones/github-cognito-openid-wrapper)
(BSD-3-Clause) does this with API Gateway and Lambda. Cognito then talks to the wrapper as a normal OIDC provider
(`oidc_providers` with `type = "OIDC"` and the wrapper's address as `issuer`).

How the pieces fit:
1. Create a **GitHub OAuth App** (not a GitHub App). Its callback URL is `https://<cognito-domain-host>/oauth2/idpresponse`.
2. Deploy the wrapper (its own SAM/CloudFormation stack or a Terraform copy of it) with the GitHub client ID and secret.
3. In Cognito add an OIDC provider that points at the wrapper. Scopes: `openid read:user user:email`.
4. Everything after that (domain check, DCR, Gateway) is unchanged.

What to watch (from the project's README and source):
- It is community software, not from AWS or GitHub. It has its own signing key, kept in a file at deploy time. **Key rotation is not supported.**
- Debug logging can write personal data to the logs, so keep the log level low.
- No refresh tokens. Cognito's OIDC discovery does not work with the Lambda version, so the endpoints are entered by hand.
- Email: it takes the user's **primary** email and passes GitHub's `verified` flag through as `email_verified`.
  So `allowed_email_domains` can still work, but only for people whose primary GitHub email is a verified company address.
  Many people use a personal address on GitHub, so a GitHub login is better restricted by something else (for example membership of a GitHub organisation).
- The token you get from Cognito is not a GitHub token, so it cannot be used to call GitHub.
- Maintenance (checked 3 November 2026 on GitHub): last release 2.0.0 in November 2024 (dropped Node 14/16, added Node 20), last push February 2026,
  not archived, about 326 stars, 19 open issues. So it is alive but slow. Several other copies and a CDK construct exist; the CDK construct is archived and one proxy repository (poad) no longer exists.
- The wrapper's discovery document does not work with Cognito on the Lambda version, so the module would need the manual endpoints
  (authorize, token, userinfo and jwks addresses) as optional inputs.
- It has no "only members of GitHub organisation X" check. That needs an extra GitHub call (scope `read:org`) inside the wrapper, not in Cognito.

### Other ways to get GitHub into Cognito
| Option | How | Good | Not so good |
|---|---|---|---|
| Existing wrapper (above) | Lambda + API Gateway, GitHub OAuth App | Fastest to try; small; cheap | Community code; key in a file; no key rotation; no org check |
| Own small wrapper in this module | A Lambda of roughly 100 lines (authorize, token, userinfo, jwks, discovery) signing with an AWS KMS key | Fits Terraform; no key file; can add an org check | We own security-sensitive code; more work |
| Dex (CNCF OIDC broker) | A server with a GitHub connector; Cognito uses it as OIDC | Mature; restricts by GitHub org and team; sends groups | Needs a running service (cost and upkeep) |
| Hosted broker (Auth0, Okta, Keycloak, ...) | Broker offers GitHub login, Cognito federates to the broker over OIDC | Little code; supported product | Another vendor, bill and login hop |

I found no sign that Cognito has added GitHub natively, or that GitHub login now returns OIDC ID tokens (searched 3 November 2026; I could not confirm either way from GitHub's own docs).

### Why we chose the existing wrapper for the first try
- It is the quickest way to find out whether GitHub login works in this setup at all (hours, not days).
- It needs no always-on server, only Lambda and API Gateway, so it costs almost nothing and is easy to delete.
- Cognito, the Gateway, dynamic client registration and the domain check stay unchanged.
- The weak points (key in the code bundle, no key rotation, old dependencies, no organisation check) are known and listed above.
  If GitHub login is needed for real, the next step is our own small wrapper with an AWS KMS signing key, or Dex.

### What was built (3 November 2026)
1. **Build the wrapper** (do this once, outside the module). Used commit `9f56e3a` (release 2.0.0) of the project:
   ```
   git clone https://github.com/TimothyJones/github-cognito-openid-wrapper.git
   cd github-cognito-openid-wrapper
   npm ci          # also creates a fresh signing key (needs ssh-keygen and openssl)
   npm audit fix   # at the time of the build this brought the production dependencies to 0 known issues
   npx webpack     # builds the dist-lambda folder
   ```
   The signing key is a new one made on your own machine and is bundled into the code. Do not reuse a key between environments.
2. **GitHub OAuth App** (Settings, Developer settings, **OAuth Apps**; not a GitHub App). Callback address:
   `https://<cognito-domain-host>/oauth2/idpresponse`. Wildcard matching off. Copy the client ID and create a client secret.
3. **Terraform:** `modules/github-oidc-wrapper` deploys five small Lambda functions behind a REST API Gateway
   (authorize, token, userinfo, jwks and discovery) using Node.js 22 (the project's own template still says Node.js 18, which is too old).
   The main module got an optional `endpoints` setting on an `oidc_providers` entry, because Cognito's automatic discovery
   does not work with this wrapper. See `examples/basic` for how the pieces are wired:
   ```hcl
   module "github_wrapper" {
     source               = "<path-to>/modules/github-oidc-wrapper"
     name_prefix          = "tf"
     source_dir           = "<path-to>/github-cognito-openid-wrapper/dist-lambda"
     github_client_id     = "<client-id>"
     github_client_secret = var.github_client_secret      # TF_VAR_github_client_secret, never in git
     cognito_redirect_uri = "https://<cognito-domain-host>/oauth2/idpresponse"
   }

   oidc_providers = {
     GitHub = {
       type      = "OIDC"
       client_id = "<client-id>"
       issuer    = module.github_wrapper.issuer
       scopes    = "openid read:user user:email"
       endpoints = module.github_wrapper.endpoints
     }
   }
   oidc_client_secrets = { GitHub = var.github_client_secret }
   ```
   The `client_id` given to Cognito must be the GitHub client ID, because the wrapper hands it on to GitHub.
4. Apply result: 42 resources added, 3 changed, none destroyed.

### Result (tested with Claude Code)
| Test | Result |
|---|---|
| Wrapper addresses (discovery, key list, authorize redirect to GitHub, userinfo without token) | Work as expected |
| Login page shows Google and GitHub | Yes (clients registered after the change; older clients must register again) |
| GitHub account whose primary email is **fivexl.io** | Allowed. Cognito creates a user named `GitHub_<GitHub user id>`; Claude Code connected |
| GitHub account whose primary email is **gmail.com** | Rejected by the domain check ("domain gmail.com is not allowed") |

So `allowed_email_domains` works for GitHub too, because the wrapper passes GitHub's primary email and its verified flag through.

### Things that went wrong or were easy to miss
- GitHub has two app types. The wrapper needs an **OAuth App**. A "GitHub App" has a different form and does not work.
- The newer GitHub form calls the callback field **Redirect URIs**. It is the same address.
- A second login attempt while the first failed in Claude Code ended with "localhost refused to connect", because Claude Code had already closed its local listener. Start one clean attempt (close old tabs).
- Cognito's session cookie can reuse a previous sign-in; use a private window when switching accounts.
- The Google provider shows a harmless change in every plan: Cognito fills in Google's standard addresses on its side and Terraform wants to remove them. Applying it does not affect the login.
- A browser tab with the previous Cognito login can show the old provider list; clients registered before the change do not know the new provider.

### Still open for GitHub
- Restrict by **GitHub organisation** (not only by email). Needs the `read:org` scope and a membership check inside the wrapper.
- Key rotation, and keeping the signing key out of the code bundle (KMS).
- Keep the GitHub client secret out of the Lambda settings (for example read it from AWS Systems Manager at run time).
- Decide who owns the GitHub OAuth App (a company organisation rather than a personal account).
- Deleting everything: `terraform destroy`, and delete the GitHub OAuth App.

---

## 5. SAML providers (Google Workspace SAML app, IAM Identity Center)

SAML is the older, XML based way for a company login system to tell an application who a person is. OIDC and SAML differ only in the
login step: Cognito still issues its own tokens, so the Gateway and the dynamic client registration do not change.

**Two things go to the provider, one file comes back.** The same pattern as in the AWS sample for Google Workspace
(AWS Security Blog, October 2023, and `GoogleInstructions.md` in `aws-samples/amazon-cognito-example-for-multi-tenant`; the Google screens may have changed since):

| Direction | Value | Example |
|---|---|---|
| To the provider | ACS URL (where the provider sends the answer) | `https://<cognito-domain-host>/saml2/idpresponse` |
| To the provider | Entity ID of the app (called "audience" in some products) | `urn:amazon:cognito:sp:<user-pool-id>` |
| To the provider | Name ID format and value | EMAIL, primary email |
| To the provider | Attribute mapping | primary email sent as the attribute `email` |
| From the provider | Metadata file (provider entity ID, sign-in address, signing certificate) | `GoogleIDPMetadata.xml`, or build one from the three values |

The two entity IDs are different things: the provider has one (who the login system is) and the app has one (who is asking). Do not mix them up.
Certificate and sign-in addresses are public information, not secrets.

### Google Workspace (a Workspace admin does this part)
1. Admin console, Apps, Web and mobile apps, **Add custom SAML app**. Download the metadata (or note the Entity ID, SSO URL and certificate).
2. Service provider details: ACS URL and Entity ID from the table above. Name ID format **EMAIL**, Name ID **Basic Information, Primary email**.
3. Attribute mapping: **Primary email** to an app attribute. Write down the **exact name**: Cognito must use the same text (see "Attribute names must match exactly").
4. **User access: ON** for everyone (or the right group or organisational unit). Without this Google answers
   `403 app_not_configured_for_user` ("Service is not configured for this user").

### In Terraform
```hcl
saml_providers = {
  GoogleSAML = {
    metadata_file = file("google-saml-metadata.xml")   # or metadata_url = "https://..."
    attribute_mapping = { email = "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/email" }   # the exact name Google sends (default is "email")
  }
}
```
If the provider only gives the three values (entity ID, sign-in address, certificate), the metadata file can be written by hand
(an `EntityDescriptor` with an `IDPSSODescriptor`, the certificate under `KeyDescriptor`, and the sign-in address as `SingleSignOnService`).
The example does this in `examples/basic/google-saml-metadata.xml` (ignored by git).

### The domain check with SAML
SAML does not send `email_verified`, and **Cognito then stores it as false**. A plain "verified" rule would therefore reject every SAML user
(this happened in the first test, 4 November 2026: "Rejected: email not verified").
The check Lambda (`lambda/signup/index.py`) now has a `TRUSTED_PROVIDERS` setting, filled automatically with the names in `saml_providers`.
For a user that comes from one of these providers the verified flag is ignored and **only the email domain is checked**.
- At first sign-in the provider is recognised by the user name Cognito gives the new user (`<Provider>_<id>`).
- When tokens are issued it is recognised from the user's `identities` attribute, so a normal user who picks a name like `GoogleSAML_x` cannot use it.
- Google and GitHub logins still need `email_verified = true`.

This is acceptable when the SAML provider is the company's own login system. Do not list a provider you do not control.

**Why the user still shows "email verified: no".** The SAML message carries no "this email was checked" fact, and Google's attribute mapping can only send
directory fields. It is cosmetic: the Gateway and the MCP clients do not read the flag, and our check handles it. Ideas if it is ever needed (not tried):
let the pre sign-up Lambda ask Cognito to auto-verify the email, add the claim in the pre token step, or set the attribute afterwards with a small post-confirmation Lambda.

### Attribute names must match exactly
Google sends the email under the name the admin typed in the SAML attribute mapping. In our test the Workspace admin used the long names
`http://schemas.xmlsoap.org/ws/2005/05/identity/claims/email` (also `.../firstName`, `.../lastName`, `.../groups`).
Cognito must be given exactly the same text, otherwise the email is not found and the check answers "no email address".
In the example this is the variable `google_saml_email_attribute` (in `saml.auto.tfvars`); in the module it is `attribute_mapping = { email = "<exact name>" }`.
If the admin screen cuts the name off, ask the admin to paste it as text (or look at the SAML answer with a tool such as SAML-tracer, only while testing).

### Sign-in must start at Cognito (IdP-initiated sign-in does not work here)
Clicking the app tile in the Google apps menu starts the login on Google's side. Cognito then answers
`Required request parameter 'RelayState' for method parameter type String is not present`.
That is expected. Cognito can accept such logins (setting `IDPInit`), but it is off by default, needs a `RelayState` with the request details, is less safe,
and an app client with it cannot also offer Google, GitHub or other non-SAML providers. MCP clients always start the login at Cognito, so the tile is not needed.

### Status (4 November 2026)
- **Works end to end.** Direct login test ended on `localhost:33418/callback?code=...`, the user `GoogleSAML_<email>` was created with the right email,
  the log says `Allowed: domain fivexl.io (trusted provider GoogleSAML)`, and Claude Code connected through the Cognito login page ("Authentication successful").
- What was needed on the Google side (done by the Workspace admin): ACS URL and Entity ID from the table above, Name ID = primary email,
  attribute mapping with the long names (saved), User access ON for the organisational unit.
- What was needed on our side: the metadata file from Google's three values (sign-in address, entity ID, certificate valid until 8 November 2028),
  the exact attribute name, and the trusted-provider rule above.
- Identity Center works with the same input (section 3). Not tried: group-based authorization (Google and Identity Center can send groups).
- Tip for testing: use a direct address instead of Claude Code, so an old Cognito session cannot hide the result:
  `https://<cognito-domain-host>/oauth2/authorize?identity_provider=GoogleSAML&response_type=code&client_id=<client-id>&redirect_uri=http://localhost:33418/callback&scope=openid+email&prompt=login`.
  A final "This site can't be reached" page at `localhost:33418/callback?code=...` means success (the user appears in Cognito). The same page with `?error=...` means refusal.

---

## 6. Restricting by group (version 1)

Signing in proves who a person is, and the email domain says which company they belong to. A **group** says what role they have.
With `allowed_groups` only people in at least one of the listed groups get tokens, and their groups are written into the token as the
`cognito:groups` claim, so the gateway and other services can use them.

```hcl
saml_providers = {
  GoogleSAML = {
    metadata_file    = file("google-saml-metadata.xml")
    groups_attribute = "http://schemas.xmlsoap.org/ws/2005/05/identity/claims/groups"   # the exact name set in the app
  }
}
allowed_groups = ["developers"]
```

### How the groups travel
1. The identity provider sends the person's groups in the SAML login, under an attribute name the admin chose.
2. Cognito stores them in the custom user attribute `custom:groups`. The module adds this attribute to the pool (attributes can be added to an
   existing pool, never changed or removed) and maps `groups_attribute` to it.
3. The check function reads it **every time tokens are issued** and refuses the person if no group matches.
4. It writes the groups into the `cognito:groups` claim of the ID and access token.
5. Optional, experimental: `require_groups_at_gateway = true` makes the AgentCore Gateway also require that claim to contain one of the groups.
   The gateway match is exact and case-sensitive, so use the group names exactly as they appear in the token.

### Setting it up in Google Workspace
In the SAML app, under **Attribute mapping, Group membership**, add the groups and give them an app attribute name (for example the same long
`.../claims/groups` style as the other attributes). Put that exact name into `groups_attribute`. Matching in the check function ignores case and
accepts a group address (`name@domain`) for the group name.

### What happens
| Person | Result |
|---|---|
| In an allowed group | Gets tokens; groups appear in `cognito:groups` |
| Not in an allowed group | Refused: "Sign-in is limited to approved groups" |
| From a provider that sends no groups (plain Google login, GitHub) or a Cognito user | Refused while `allowed_groups` is set |
| Any person, when `allowed_groups` is empty | Not restricted; their groups (if the provider sent any) are still written into the token |

### Limits
- Only providers that send groups work: SAML providers with `groups_attribute`. IAM Identity Center is not tried: it depends on whether the application can send groups.
- A group change at the provider applies at the **next full sign-in**, not when a token is refreshed.
- The attribute holds at most 2,048 characters, which is enough for a few dozen group names but not for hundreds.
- People created before the attribute existed have it empty until their next SAML sign-in.
- How Cognito stores a list of several groups from SAML is not documented in detail; the check function accepts a JSON list and lists separated by commas, semicolons or line breaks.

### Status
Built and unit-tested (the check function, the token claim and the group matching). Not yet tested live with a real SAML login.
To test: set `groups_attribute` and `allowed_groups`, apply, sign in with a person who is in the group (should work, and `custom:groups` appears on the user in Cognito),
then change `allowed_groups` to a group the person is not in and sign in again (should be refused, with the reason in the check function's log).
Next versions: map groups to scopes (read and write) and add per-tool rules with the gateway's Cedar policies.

---

## Future ideas
- Cognito's own passwordless sign-in (passkeys or an email code) is a possible option without an external provider. Not tested.



