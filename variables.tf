variable "name_prefix" {
  description = "Prefix for all resource names. Also used as the identifier of the Cognito resource server, so scopes look like <prefix>/read."
  type        = string
  default     = "mcp"
}

variable "tool_lambda_arn" {
  description = "ARN of the Lambda function the AgentCore Gateway forwards tool calls to."
  type        = string
}

variable "tools" {
  description = "Tools exposed through the Gateway. Each tool needs a name and a description; properties describe its input."
  type = list(object({
    name        = string
    description = string
    properties = optional(list(object({
      name        = string
      type        = string
      description = optional(string)
      required    = optional(bool, false)
    })), [])
  }))
  default = [
    {
      name        = "hello"
      description = "Returns a greeting."
      properties = [
        {
          name        = "name"
          type        = "string"
          description = "Name to greet."
        }
      ]
    }
  ]
}

# ---------------------------------------------------------------------------
# Cognito
# ---------------------------------------------------------------------------

variable "create_user_pool" {
  description = "Create a Cognito user pool. Set to false to use an existing one (then user_pool_id and cognito_domain_host are required)."
  type        = bool
  default     = true
}

variable "user_pool_id" {
  description = "ID of an existing Cognito user pool. Only used when create_user_pool is false."
  type        = string
  default     = null
}

variable "cognito_domain_prefix" {
  description = "Prefix for the Cognito hosted login domain (<prefix>.auth.<region>.amazoncognito.com). Required when create_user_pool is true. Must be unique in the region and must not contain the words aws, amazon or cognito."
  type        = string
  default     = null
}

variable "cognito_domain_host" {
  description = "Full hosted login host of an existing user pool (for example xyz.auth.us-east-1.amazoncognito.com). Only used when create_user_pool is false."
  type        = string
  default     = null
}

variable "create_resource_server" {
  description = "Create the Cognito resource server that defines the custom scopes. Set to false if the existing pool already has one with the same identifier."
  type        = bool
  default     = true
}

variable "resource_server_scopes" {
  description = "Custom scope names. They become <name_prefix>/<scope>."
  type        = list(string)
  default     = ["read", "write"]
}

variable "include_cognito_users" {
  description = "Allow registered clients to sign in with Cognito's own users (username and password). Set to false for passwordless setups that only use external providers."
  type        = bool
  default     = true
}

variable "oidc_providers" {
  description = <<-EOT
    External OpenID Connect providers to create in the user pool, keyed by the provider name shown in Cognito.
    type is "Google" (Google's built-in provider) or "OIDC" (any provider with an issuer address, for example Okta or Entra).
    issuer is required for type OIDC. The client secrets go in oidc_client_secrets, not here.
  EOT
  type = map(object({
    type              = optional(string, "OIDC")
    client_id         = string
    issuer            = optional(string)
    scopes            = optional(string, "openid email profile")
    attribute_mapping = optional(map(string), { email = "email", email_verified = "email_verified", name = "name", username = "sub" })
    # Only for providers whose discovery document does not work with Cognito (for example the GitHub wrapper).
    endpoints = optional(object({
      authorize_url  = string
      token_url      = string
      attributes_url = string
      jwks_uri       = string
    }))
  }))
  default = {}

  validation {
    condition     = alltrue([for k, v in var.oidc_providers : contains(["OIDC", "Google"], v.type)])
    error_message = "Each oidc_providers type must be \"OIDC\" or \"Google\"."
  }

  validation {
    condition     = alltrue([for k, v in var.oidc_providers : v.type != "Google" || k == "Google"])
    error_message = "Cognito requires the provider name of a Google provider to be exactly \"Google\" (capital G)."
  }

  validation {
    condition     = alltrue([for k, v in var.oidc_providers : v.type != "OIDC" || v.issuer != null])
    error_message = "Providers of type OIDC need an issuer, for example https://accounts.example.com."
  }
}

variable "oidc_client_secrets" {
  description = "Client secrets of the providers in oidc_providers, keyed by the same provider names. Keep them out of git (environment variable TF_VAR_oidc_client_secrets or an untracked tfvars file)."
  type        = map(string)
  default     = {}
  sensitive   = true
}

variable "saml_providers" {
  description = <<-EOT
    SAML 2.0 identity providers to create in the user pool, keyed by the provider name shown in Cognito
    (for example Google Workspace SAML app or IAM Identity Center). Give either metadata_file (the provider's
    metadata XML as text, for example file("metadata.xml")) or metadata_url (a public address). The provider is told
    about the user pool through the ACS URL https://<cognito-domain-host>/saml2/idpresponse and the entity ID
    urn:amazon:cognito:sp:<user-pool-id>. The attribute mapping keys are Cognito attributes and the values are the
    attribute names the provider sends (for example email = "email"). groups_attribute is the name of the SAML
    attribute that carries the person's groups (for example the long
    http://schemas.xmlsoap.org/ws/2005/05/identity/claims/groups address a Google Workspace app uses); the module
    stores it in the custom user attribute custom:groups so that allowed_groups can use it.
  EOT
  type = map(object({
    metadata_file     = optional(string)
    metadata_url      = optional(string)
    attribute_mapping = optional(map(string), { email = "email" })
    groups_attribute  = optional(string)
  }))
  default = {}

  validation {
    condition     = alltrue([for k, v in var.saml_providers : (v.metadata_file != null) != (v.metadata_url != null)])
    error_message = "Each SAML provider needs exactly one of metadata_file or metadata_url."
  }
}

variable "allowed_email_domains" {
  description = "Only people whose verified email is in one of these domains (for example [\"example.com\"]) may be created in the user pool, checked at first sign-in. Empty means no restriction. Needs create_user_pool = true."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for d in var.allowed_email_domains : can(regex("^[a-z0-9.-]+\\.[a-z]{2,}$", d))])
    error_message = "Each domain must look like example.com (lower case, no @)."
  }
}

variable "allowed_groups" {
  description = <<-EOT
    Only people who belong to at least one of these groups may get tokens (for example ["developers"]). Empty means no
    group restriction. Groups come from the identity provider, so this works with the providers that send them:
    SAML providers with groups_attribute set. People from providers that send no groups (plain Google login, GitHub,
    Cognito users) are refused while this is set. The list is also written into the token as the cognito:groups claim.
    Matching in the check function ignores case and also accepts a group address (name@domain) for the name.
    Needs create_user_pool = true. Group changes at the provider apply at the next full sign-in, not on a token refresh.
  EOT
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for g in var.allowed_groups : length(trimspace(g)) > 0 && !can(regex(",", g))])
    error_message = "Group names must not be empty and must not contain a comma."
  }
}

variable "group_scopes" {
  description = <<-EOT
    Roles by group (version 2): maps a group to the custom scopes its members may hold, for example
    { developers = ["read", "write"], viewers = ["read"] }. The scope names must be in resource_server_scopes.
    People only keep the scopes their groups allow; the others are removed from their access token. A person in no
    listed group keeps none of the custom scopes. Needs the Essentials or Plus Cognito plan (the module then asks
    Cognito for version 2 trigger events) and create_user_pool = true. The gateway does not check scopes by
    itself: use it together with per-tool rules, or a client or service that reads the scope claim.
  EOT
  type        = map(list(string))
  default     = {}
}

variable "require_groups_at_gateway" {
  description = "Experimental. Also make the AgentCore Gateway require that the token's cognito:groups claim contains one of allowed_groups (exact, case-sensitive match). The check function already refuses people outside the groups; this adds a second check at the gateway. Test before relying on it."
  type        = bool
  default     = false
}

variable "managed_login_version" {
  description = "Cognito login page version: 1 is the classic hosted UI, 2 is the newer managed login. AWS's current Google guide asks for managed login (2); the classic page may also show provider buttons. Test with your provider."
  type        = number
  default     = 1
}

variable "identity_providers" {
  description = "Extra identity providers that registered clients may use besides Cognito's own users, for example [\"Google\"] or [\"IdentityCenter\"]. The names must match providers configured in the user pool."
  type        = list(string)
  default     = []
}

# ---------------------------------------------------------------------------
# Dynamic client registration
# ---------------------------------------------------------------------------

variable "redirect_uri_allow_patterns" {
  description = "Regular expressions a client's redirect URIs must match to be registered. The defaults allow Claude (web, Desktop, mobile), loopback addresses used by Claude Code, the MCP Inspector and Cursor. Patterns are matched from the start of the address, so end them with $ to match exactly. Use [\".*\"] to allow everything."
  type        = list(string)
  default = [
    "^https://claude\\.ai/api/mcp/auth_callback$",
    "^https://www\\.cursor\\.com/agents/mcp/oauth/callback$",
    "^cursor://anysphere\\.cursor-mcp/oauth/callback$",
    "^http://(localhost|127\\.0\\.0\\.1)(:[0-9]+)?(/.*)?$",
  ]

  validation {
    condition     = length(var.redirect_uri_allow_patterns) > 0
    error_message = "redirect_uri_allow_patterns must not be empty (an empty list would refuse every registration). Use [\".*\"] on purpose to allow every callback address."
  }
}

variable "register_throttle_rate_limit" {
  description = "Steady request rate (per second) allowed on the public API, including /register."
  type        = number
  default     = 5
}

variable "register_throttle_burst_limit" {
  description = "Burst limit on the public API, including /register."
  type        = number
  default     = 10
}

variable "log_retention_days" {
  description = "Retention of the registration function's CloudWatch logs."
  type        = number
  default     = 14
}

variable "tags" {
  description = "Tags added to all resources that support them."
  type        = map(string)
  default     = {}
}

variable "registration_enabled" {
  description = "Switch for POST /register. false answers every registration with 403, so no new clients appear (existing clients keep working). Use it when you are not onboarding clients."
  type        = bool
  default     = true
}

variable "max_registered_clients" {
  description = "Hard cap on the number of app clients in the user pool. When the pool has this many, /register answers 429 instead of creating one. 0 means no cap (Cognito's own limit, 1,000 by default, still applies; every reconnect of a client registers a new one, so a cap or a clean-up is advisable)."
  type        = number
  default     = 0

  validation {
    condition     = var.max_registered_clients >= 0
    error_message = "max_registered_clients must be 0 (no cap) or more."
  }
}

variable "access_token_validity_minutes" {
  description = "How long an access token is valid, for the initial client and every registered client."
  type        = number
  default     = 60

  validation {
    condition     = var.access_token_validity_minutes >= 5 && var.access_token_validity_minutes <= 1440
    error_message = "access_token_validity_minutes must be between 5 and 1440."
  }
}

variable "refresh_token_validity_hours" {
  description = "How long a refresh token is valid. This is also how long a person keeps access after they are removed at the identity provider, because the groups and the account are only checked again at the next full sign-in. Shorter is safer; people sign in again more often."
  type        = number
  default     = 24

  validation {
    condition     = var.refresh_token_validity_hours >= 1 && var.refresh_token_validity_hours <= 8760
    error_message = "refresh_token_validity_hours must be between 1 and 8760."
  }
}

variable "user_pool_deletion_protection" {
  description = "Protect the user pool from deletion. Deleting it removes every user and client at once. Needs create_user_pool = true."
  type        = bool
  default     = false
}

variable "allow_self_signup" {
  description = "Allow people to create their own Cognito account in the hosted login. false (the default) means only an administrator creates native users; people from SAML and OpenID Connect providers are not affected. Needs create_user_pool = true."
  type        = bool
  default     = false
}

variable "gateway_required_scopes" {
  description = "Scope names (from resource_server_scopes) of which a token must carry at least one for the Gateway to accept it, for example [\"read\"]. Together with group_scopes this is what turns the scopes into an access decision at the gateway: a person with none of them is refused. Empty means the Gateway does not check scopes. Which scopes AgentCore requires when several are listed (any one or all) is not verified, so list one until it is tested."
  type        = list(string)
  default     = []
}
