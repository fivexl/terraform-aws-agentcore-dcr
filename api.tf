locals {
  stage_name = "prod"
  api_base   = "https://${aws_api_gateway_rest_api.this.id}.execute-api.${local.region}.amazonaws.com/${local.stage_name}"

  # Login description served to clients. It is Cognito's own description plus
  # the registration endpoint, which Cognito does not offer.
  oidc_document = {
    issuer                                = "https://cognito-idp.${local.region}.amazonaws.com/${local.user_pool_id}"
    authorization_endpoint                = "https://${local.cognito_host}/oauth2/authorize"
    token_endpoint                        = "https://${local.cognito_host}/oauth2/token"
    userinfo_endpoint                     = "https://${local.cognito_host}/oauth2/userInfo"
    revocation_endpoint                   = "https://${local.cognito_host}/oauth2/revoke"
    jwks_uri                              = "https://cognito-idp.${local.region}.amazonaws.com/${local.user_pool_id}/.well-known/jwks.json"
    registration_endpoint                 = "${local.api_base}/register"
    scopes_supported                      = local.all_scopes
    response_types_supported              = ["code"]
    grant_types_supported                 = ["authorization_code", "refresh_token"]
    subject_types_supported               = ["public"]
    id_token_signing_alg_values_supported = ["RS256"]
    token_endpoint_auth_methods_supported = ["none", "client_secret_basic", "client_secret_post"]
    code_challenge_methods_supported      = ["S256"]
  }
}

resource "aws_api_gateway_rest_api" "this" {
  name        = "${var.name_prefix}-oauth-metadata"
  description = "Login description and dynamic client registration for the AgentCore Gateway"
  tags        = var.tags

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

resource "aws_api_gateway_resource" "well_known" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = ".well-known"
}

resource "aws_api_gateway_resource" "oidc" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_resource.well_known.id
  path_part   = "openid-configuration"
}

resource "aws_api_gateway_resource" "register" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = "register"
}

# GET /.well-known/openid-configuration (static document)
resource "aws_api_gateway_method" "oidc_get" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.oidc.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "oidc_get" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.oidc.id
  http_method = aws_api_gateway_method.oidc_get.http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = jsonencode({ statusCode = 200 })
  }
}

resource "aws_api_gateway_method_response" "oidc_get" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.oidc.id
  http_method = aws_api_gateway_method.oidc_get.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Content-Type"                = true
    "method.response.header.Access-Control-Allow-Origin" = true
  }
}

resource "aws_api_gateway_integration_response" "oidc_get" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.oidc.id
  http_method = aws_api_gateway_method.oidc_get.http_method
  status_code = aws_api_gateway_method_response.oidc_get.status_code

  response_parameters = {
    "method.response.header.Content-Type"                = "'application/json'"
    "method.response.header.Access-Control-Allow-Origin" = "'*'"
  }

  response_templates = {
    "application/json" = jsonencode(local.oidc_document)
  }

  depends_on = [aws_api_gateway_integration.oidc_get]
}

# POST /register (Lambda)
resource "aws_api_gateway_method" "register_post" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.register.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "register_post" {
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.register.id
  http_method             = aws_api_gateway_method.register_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.dcr.invoke_arn
}

# OPTIONS /register (CORS preflight for browser based clients)
resource "aws_api_gateway_method" "register_options" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.register.id
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "register_options" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.register.id
  http_method = aws_api_gateway_method.register_options.http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = jsonencode({ statusCode = 200 })
  }
}

resource "aws_api_gateway_method_response" "register_options" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.register.id
  http_method = aws_api_gateway_method.register_options.http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin"  = true
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
  }
}

resource "aws_api_gateway_integration_response" "register_options" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.register.id
  http_method = aws_api_gateway_method.register_options.http_method
  status_code = aws_api_gateway_method_response.register_options.status_code

  response_parameters = {
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type'"
    "method.response.header.Access-Control-Allow-Methods" = "'POST,OPTIONS'"
  }

  depends_on = [aws_api_gateway_integration.register_options]
}

resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_integration.oidc_get,
      aws_api_gateway_integration_response.oidc_get,
      aws_api_gateway_integration.register_post,
      aws_api_gateway_integration.register_options,
      aws_api_gateway_integration_response.register_options,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "this" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  deployment_id = aws_api_gateway_deployment.this.id
  stage_name    = local.stage_name
  tags          = var.tags
}

# /register is open to the internet by design, so limit how fast it can be called.
resource "aws_api_gateway_method_settings" "all" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  stage_name  = aws_api_gateway_stage.this.stage_name
  method_path = "*/*"

  settings {
    throttling_rate_limit  = var.register_throttle_rate_limit
    throttling_burst_limit = var.register_throttle_burst_limit
  }
}
