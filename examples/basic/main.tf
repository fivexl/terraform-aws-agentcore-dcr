terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.4"
    }
  }
}

provider "aws" {
  region = var.region
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "name_prefix" {
  type    = string
  default = "tf"
}

variable "cognito_domain_prefix" {
  description = "Unique prefix for the Cognito hosted login domain (no 'aws', 'amazon' or 'cognito' in it)."
  type        = string
}

variable "oidc_providers" {
  description = "Optional external OIDC providers (see the module README). Empty by default: Cognito users only."
  type = map(object({
    type              = optional(string, "OIDC")
    client_id         = string
    issuer            = optional(string)
    scopes            = optional(string, "openid email profile")
    attribute_mapping = optional(map(string), { email = "email", email_verified = "email_verified", name = "name", username = "sub" })
    endpoints = optional(object({
      authorize_url  = string
      token_url      = string
      attributes_url = string
      jwks_uri       = string
    }))
  }))
  default = {}
}

variable "oidc_client_secrets" {
  description = "Client secrets for oidc_providers, keyed by provider name. Pass them with TF_VAR_oidc_client_secrets or an untracked tfvars file."
  type        = map(string)
  default     = {}
  sensitive   = true
}

variable "allowed_email_domains" {
  type    = list(string)
  default = []
}

variable "include_cognito_users" {
  type    = bool
  default = true
}

# Optional GitHub login. GitHub is plain OAuth, so a small wrapper makes it look like OIDC for Cognito.
# Leave github_client_id empty to skip it. See docs/identity-providers.md (section 4).
variable "github_client_id" {
  description = "Client ID of a GitHub OAuth App. Empty means no GitHub login."
  type        = string
  default     = null
}

variable "github_client_secret" {
  description = "Client secret of the GitHub OAuth App. Pass it with TF_VAR_github_client_secret, never in a committed file."
  type        = string
  default     = null
  sensitive   = true
}

variable "github_wrapper_dir" {
  description = "Folder with the built wrapper (its dist-lambda folder). See docs/identity-providers.md (section 4)."
  type        = string
  default     = null
}

# Optional Google Workspace SAML app (SAML is the other way to federate, see docs/identity-providers.md).
variable "google_saml_email_attribute" {
  description = "Name of the SAML attribute Google sends the primary email in (the exact text from the Google admin SAML attribute mapping, for example a long http://schemas.xmlsoap.org/... address)."
  type        = string
  default     = "email"
}

variable "google_saml_metadata_path" {
  description = "Path to the metadata XML of a Google Workspace SAML app. Empty means no SAML provider."
  type        = string
  default     = null
}

variable "idc_saml_metadata_path" {
  description = "Path to the SAML metadata XML downloaded from an IAM Identity Center customer managed application. Empty means no Identity Center provider."
  type        = string
  default     = null
}

locals {
  github_enabled = var.github_client_id != null

  tags = {
    owner   = "example"
    purpose = "agentcore-dcr"
  }
}

# A tiny tool for the Gateway to call.
data "archive_file" "tool" {
  type        = "zip"
  source_dir  = "${path.module}/tool"
  output_path = "${path.module}/.build/tool.zip"
}

data "aws_iam_policy_document" "tool_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "tool" {
  name               = "${var.name_prefix}-example-tool-role"
  assume_role_policy = data.aws_iam_policy_document.tool_assume.json
  tags               = local.tags
}

resource "aws_iam_role_policy_attachment" "tool_logs" {
  role       = aws_iam_role.tool.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_lambda_function" "tool" {
  function_name    = "${var.name_prefix}-example-tool"
  role             = aws_iam_role.tool.arn
  runtime          = "python3.12"
  handler          = "lambda_function.lambda_handler"
  filename         = data.archive_file.tool.output_path
  source_code_hash = data.archive_file.tool.output_base64sha256
  tags             = local.tags
}

module "github_wrapper" {
  count  = local.github_enabled ? 1 : 0
  source = "../../modules/github-oidc-wrapper"

  name_prefix          = var.name_prefix
  source_dir           = var.github_wrapper_dir
  github_client_id     = var.github_client_id
  github_client_secret = var.github_client_secret
  cognito_redirect_uri = "https://${var.cognito_domain_prefix}.auth.${var.region}.amazoncognito.com/oauth2/idpresponse"
  tags                 = local.tags
}

module "agentcore_dcr" {
  source = "../.."

  name_prefix           = var.name_prefix
  cognito_domain_prefix = var.cognito_domain_prefix
  tool_lambda_arn       = aws_lambda_function.tool.arn
  tags                  = local.tags

  oidc_providers = merge(var.oidc_providers, local.github_enabled ? {
    GitHub = {
      type      = "OIDC"
      client_id = var.github_client_id
      issuer    = module.github_wrapper[0].issuer
      scopes    = "openid read:user user:email"
      endpoints = module.github_wrapper[0].endpoints
    }
  } : {})
  saml_providers = merge(
    var.google_saml_metadata_path == null ? {} : {
      GoogleSAML = {
        metadata_file     = file(var.google_saml_metadata_path)
        attribute_mapping = { email = var.google_saml_email_attribute }
      }
    },
    # IAM Identity Center sends the attribute "email" (the mapping set in the application).
    var.idc_saml_metadata_path == null ? {} : {
      IdentityCenter = {
        metadata_file = file(var.idc_saml_metadata_path)
      }
    },
  )
  oidc_client_secrets   = merge(var.oidc_client_secrets, local.github_enabled ? { GitHub = var.github_client_secret } : {})
  include_cognito_users = var.include_cognito_users
  allowed_email_domains = var.allowed_email_domains
}

output "gateway_mcp_url" {
  value = module.agentcore_dcr.gateway_mcp_url
}

output "dcr_endpoint" {
  value = module.agentcore_dcr.dcr_endpoint
}

output "user_pool_id" {
  value = module.agentcore_dcr.user_pool_id
}

output "cognito_domain_host" {
  value = module.agentcore_dcr.cognito_domain_host
}


