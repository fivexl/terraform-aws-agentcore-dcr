data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

locals {
  region     = data.aws_region.current.region
  account_id = data.aws_caller_identity.current.account_id

  user_pool_id  = var.create_user_pool ? aws_cognito_user_pool.this[0].id : var.user_pool_id
  user_pool_arn = "arn:aws:cognito-idp:${local.region}:${local.account_id}:userpool/${local.user_pool_id}"
  cognito_host  = var.create_user_pool ? "${var.cognito_domain_prefix}.auth.${local.region}.amazoncognito.com" : var.cognito_domain_host

  resource_scopes = [for s in var.resource_server_scopes : "${var.name_prefix}/${s}"]
  all_scopes      = concat(["openid", "email", "phone", "profile"], local.resource_scopes)
  # Providers a registered client may use: Cognito's own users (optional), the OIDC
  # providers created by this module, and any provider created elsewhere.
  client_provider = concat(
    var.include_cognito_users ? ["COGNITO"] : [],
    keys(var.oidc_providers),
    keys(var.saml_providers),
    var.identity_providers,
  )
}

resource "aws_cognito_user_pool" "this" {
  count = var.create_user_pool ? 1 : 0

  name = "${var.name_prefix}-pool"
  tags = var.tags

  dynamic "lambda_config" {
    for_each = length(var.allowed_email_domains) > 0 ? [1] : []
    content {
      pre_sign_up = aws_lambda_function.signup_domain[0].arn

      # Also check at every token issue and refresh, so existing users are covered.
      pre_token_generation_config {
        lambda_arn     = aws_lambda_function.signup_domain[0].arn
        lambda_version = "V1_0"
      }
    }
  }
}

resource "aws_cognito_user_pool_domain" "this" {
  count = var.create_user_pool ? 1 : 0

  domain                = var.cognito_domain_prefix
  user_pool_id          = aws_cognito_user_pool.this[0].id
  managed_login_version = var.managed_login_version
}

# Sign-in through an external OpenID Connect provider (Google, Okta, Entra, ...).
# Cognito then still issues its own tokens, so the Gateway does not change.
resource "aws_cognito_identity_provider" "oidc" {
  for_each = var.oidc_providers

  user_pool_id  = local.user_pool_id
  provider_name = each.key
  provider_type = each.value.type

  provider_details = each.value.type == "Google" ? {
    client_id        = each.value.client_id
    client_secret    = var.oidc_client_secrets[each.key]
    authorize_scopes = each.value.scopes
    } : merge({
      client_id                 = each.value.client_id
      client_secret             = var.oidc_client_secrets[each.key]
      authorize_scopes          = each.value.scopes
      oidc_issuer               = each.value.issuer
      attributes_request_method = "GET"
    },
    # Manual endpoints replace Cognito's automatic discovery.
    each.value.endpoints == null ? {} : {
      authorize_url  = each.value.endpoints.authorize_url
      token_url      = each.value.endpoints.token_url
      attributes_url = each.value.endpoints.attributes_url
      jwks_uri       = each.value.endpoints.jwks_uri
    }
  )

  attribute_mapping = each.value.attribute_mapping
}

# Sign-in through a SAML 2.0 provider (Google Workspace SAML app, IAM Identity Center, ...).
resource "aws_cognito_identity_provider" "saml" {
  for_each = var.saml_providers

  user_pool_id  = local.user_pool_id
  provider_name = each.key
  provider_type = "SAML"

  provider_details = merge(
    { IDPSignout = "false" },
    each.value.metadata_file != null ? { MetadataFile = each.value.metadata_file } : { MetadataURL = each.value.metadata_url },
  )

  attribute_mapping = each.value.attribute_mapping
}

resource "aws_cognito_resource_server" "this" {
  count = var.create_resource_server ? 1 : 0

  identifier   = var.name_prefix
  name         = "${var.name_prefix} MCP"
  user_pool_id = local.user_pool_id

  dynamic "scope" {
    for_each = var.resource_server_scopes
    content {
      scope_name        = scope.value
      scope_description = "${scope.value} access"
    }
  }
}

# A first client for manual setup. The Gateway needs at least one allowed client
# when it is created; clients registered later are added to the list by the
# registration function.
resource "aws_cognito_user_pool_client" "initial" {
  name         = "${var.name_prefix}-initial-client"
  user_pool_id = local.user_pool_id

  generate_secret                      = false
  explicit_auth_flows                  = ["ALLOW_REFRESH_TOKEN_AUTH", "ALLOW_USER_SRP_AUTH"]
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_scopes                 = local.all_scopes
  callback_urls                        = ["http://localhost:33418/callback", "http://127.0.0.1:33418/callback"]
  supported_identity_providers         = local.client_provider

  depends_on = [
    aws_cognito_resource_server.this,
    aws_cognito_identity_provider.oidc,
    aws_cognito_identity_provider.saml,
  ]
}


