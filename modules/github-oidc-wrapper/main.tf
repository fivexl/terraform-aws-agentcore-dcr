# Runs the community "github-cognito-openid-wrapper" (BSD-3-Clause, Timothy Jones) on Lambda and API Gateway.
# It makes GitHub (plain OAuth 2.0) look like an OpenID Connect provider, so a Cognito user pool can use it.
# The code is built separately (see the docs); this module only deploys the built files.

terraform {
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

variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
}

variable "source_dir" {
  description = "Folder with the built wrapper (the dist-lambda folder: authorize.js, token.js, userinfo.js, jwks.js, openIdConfiguration.js)."
  type        = string
}

variable "github_client_id" {
  description = "Client ID of the GitHub OAuth App."
  type        = string
}

variable "github_client_secret" {
  description = "Client secret of the GitHub OAuth App. Kept out of git; it ends up in the Lambda settings and in the Terraform state."
  type        = string
  sensitive   = true
}

variable "cognito_redirect_uri" {
  description = "https://<cognito-domain-host>/oauth2/idpresponse, the address GitHub sends people back to."
  type        = string
}

variable "github_api_url" {
  description = "Change only for GitHub Enterprise Server (https://<host>/api/v3)."
  type        = string
  default     = "https://api.github.com"
}

variable "github_login_url" {
  description = "Change only for GitHub Enterprise Server (https://<host>)."
  type        = string
  default     = "https://github.com"
}

variable "runtime" {
  description = "Lambda runtime. The wrapper uses callback-style handlers, so use nodejs22.x or older."
  type        = string
  default     = "nodejs22.x"
}

variable "throttle_rate_limit" {
  type    = number
  default = 5
}

variable "throttle_burst_limit" {
  type    = number
  default = 10
}

variable "log_retention_days" {
  type    = number
  default = 14
}

variable "tags" {
  type    = map(string)
  default = {}
}

data "aws_region" "current" {}

locals {
  stage_name = "prod"

  # name => Lambda handler (file.handler in the built folder)
  functions = {
    authorize = "authorize.handler"
    token     = "token.handler"
    userinfo  = "userinfo.handler"
    jwks      = "jwks.handler"
    discovery = "openIdConfiguration.handler"
  }

  # Every route: function, resource, HTTP method
  routes = {
    "authorize-GET" = { fn = "authorize", resource = "authorize", method = "GET" }
    "token-GET"     = { fn = "token", resource = "token", method = "GET" }
    "token-POST"    = { fn = "token", resource = "token", method = "POST" }
    "userinfo-GET"  = { fn = "userinfo", resource = "userinfo", method = "GET" }
    "userinfo-POST" = { fn = "userinfo", resource = "userinfo", method = "POST" }
    "jwks-GET"      = { fn = "jwks", resource = "jwks", method = "GET" }
    "discovery-GET" = { fn = "discovery", resource = "discovery", method = "GET" }
  }
}

data "archive_file" "code" {
  type        = "zip"
  source_dir  = var.source_dir
  output_path = "${path.module}/.build/github-wrapper.zip"
  excludes    = [for f in ["authorize", "token", "userinfo", "jwks", "openIdConfiguration"] : "${f}.js.map"]
}

data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = "${var.name_prefix}-github-wrapper-role"
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "logs" {
  role       = aws_iam_role.this.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_cloudwatch_log_group" "fn" {
  for_each = local.functions

  name              = "/aws/lambda/${var.name_prefix}-github-wrapper-${each.key}"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_lambda_function" "fn" {
  for_each = local.functions

  function_name    = "${var.name_prefix}-github-wrapper-${each.key}"
  role             = aws_iam_role.this.arn
  runtime          = var.runtime
  handler          = each.value
  filename         = data.archive_file.code.output_path
  source_code_hash = data.archive_file.code.output_base64sha256
  timeout          = 15
  tags             = var.tags

  environment {
    variables = {
      GITHUB_CLIENT_ID     = var.github_client_id
      GITHUB_CLIENT_SECRET = var.github_client_secret
      COGNITO_REDIRECT_URI = var.cognito_redirect_uri
      GITHUB_API_URL       = var.github_api_url
      GITHUB_LOGIN_URL     = var.github_login_url
    }
  }

  depends_on = [aws_cloudwatch_log_group.fn, aws_iam_role_policy_attachment.logs]
}

resource "aws_lambda_permission" "api" {
  for_each = local.functions

  statement_id  = "AllowApiGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.fn[each.key].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/*/*"
}

# ---------------------------------------------------------------------------
# API Gateway (REST, because the wrapper reads the REST proxy event format)
# ---------------------------------------------------------------------------

resource "aws_api_gateway_rest_api" "this" {
  name = "${var.name_prefix}-github-wrapper"
  tags = var.tags

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

resource "aws_api_gateway_resource" "well_known" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = ".well-known"
}

locals {
  # resource key => parent and path
  resources = {
    authorize = { parent = aws_api_gateway_rest_api.this.root_resource_id, path = "authorize" }
    token     = { parent = aws_api_gateway_rest_api.this.root_resource_id, path = "token" }
    userinfo  = { parent = aws_api_gateway_rest_api.this.root_resource_id, path = "userinfo" }
    jwks      = { parent = aws_api_gateway_resource.well_known.id, path = "jwks.json" }
    discovery = { parent = aws_api_gateway_resource.well_known.id, path = "openid-configuration" }
  }
}

resource "aws_api_gateway_resource" "r" {
  for_each = local.resources

  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = each.value.parent
  path_part   = each.value.path
}

resource "aws_api_gateway_method" "m" {
  for_each = local.routes

  rest_api_id   = aws_api_gateway_rest_api.this.id
  resource_id   = aws_api_gateway_resource.r[each.value.resource].id
  http_method   = each.value.method
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "i" {
  for_each = local.routes

  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.r[each.value.resource].id
  http_method             = aws_api_gateway_method.m[each.key].http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.fn[each.value.fn].invoke_arn
}

resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id

  triggers = {
    redeploy = sha1(jsonencode([
      local.routes,
      [for k, v in local.resources : v.path],
      [for k, v in aws_api_gateway_integration.i : v.uri],
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [aws_api_gateway_integration.i]
}

resource "aws_api_gateway_stage" "this" {
  rest_api_id   = aws_api_gateway_rest_api.this.id
  deployment_id = aws_api_gateway_deployment.this.id
  stage_name    = local.stage_name
  tags          = var.tags
}

resource "aws_api_gateway_method_settings" "all" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  stage_name  = aws_api_gateway_stage.this.stage_name
  method_path = "*/*"

  settings {
    throttling_rate_limit  = var.throttle_rate_limit
    throttling_burst_limit = var.throttle_burst_limit
  }
}

locals {
  issuer = "https://${aws_api_gateway_rest_api.this.id}.execute-api.${data.aws_region.current.region}.amazonaws.com/${local.stage_name}"
}

output "issuer" {
  description = "Issuer address of the wrapper. Use it as the issuer of an OIDC provider in the module."
  value       = local.issuer
}

output "endpoints" {
  description = "Manual endpoints for the Cognito OIDC provider (Cognito's automatic discovery does not work with the Lambda version)."
  value = {
    authorize_url  = "${local.issuer}/authorize"
    token_url      = "${local.issuer}/token"
    attributes_url = "${local.issuer}/userinfo"
    jwks_uri       = "${local.issuer}/.well-known/jwks.json"
  }
}
