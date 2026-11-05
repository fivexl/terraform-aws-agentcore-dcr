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
    attribute names the provider sends (for example email = "email").
  EOT
  type = map(object({
    metadata_file     = optional(string)
    metadata_url      = optional(string)
    attribute_mapping = optional(map(string), { email = "email" })
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
  description = "Regular expressions a client's redirect URIs must match to be registered. The defaults allow Claude (web, Desktop, mobile), loopback addresses used by Claude Code, the MCP Inspector and Cursor. Use [\".*\"] to allow everything."
  type        = list(string)
  default = [
    "^https://claude\\.ai/api/mcp/auth_callback$",
    "^https://www\\.cursor\\.com/agents/mcp/oauth/callback$",
    "^cursor://anysphere\\.cursor-mcp/oauth/callback$",
    "^http://(localhost|127\\.0\\.0\\.1)(:[0-9]+)?(/.*)?$",
  ]
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


