locals {
  gateway_name = "${var.name_prefix}-mcp-gateway"
}

data "archive_file" "dcr" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/dcr"
  output_path = "${path.module}/.build/dcr.zip"
}

resource "aws_cloudwatch_log_group" "dcr" {
  name              = "/aws/lambda/${var.name_prefix}-dcr"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

data "aws_iam_policy_document" "dcr_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "dcr" {
  name               = "${var.name_prefix}-dcr-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.dcr_assume.json
  tags               = var.tags
}

# The Lambda looks the Gateway up by name at run time. Referencing the Gateway
# here would create a dependency loop (Gateway -> API -> Lambda -> Gateway), so
# the Gateway-specific permissions are attached separately in gateway.tf.
data "aws_iam_policy_document" "dcr_base" {
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.dcr.arn}:*"]
  }

  statement {
    actions   = ["cognito-idp:CreateUserPoolClient", "cognito-idp:DeleteUserPoolClient"]
    resources = [local.user_pool_arn]
  }

  statement {
    actions   = ["bedrock-agentcore:ListGateways"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "dcr_base" {
  name   = "base"
  role   = aws_iam_role.dcr.id
  policy = data.aws_iam_policy_document.dcr_base.json
}

resource "aws_lambda_function" "dcr" {
  function_name    = "${var.name_prefix}-dcr"
  role             = aws_iam_role.dcr.arn
  runtime          = "python3.12"
  handler          = "index.handler"
  timeout          = 30
  filename         = data.archive_file.dcr.output_path
  source_code_hash = data.archive_file.dcr.output_base64sha256
  tags             = var.tags

  environment {
    variables = {
      USER_POOL_ID          = local.user_pool_id
      GATEWAY_NAME          = local.gateway_name
      RESOURCE_SCOPES       = join(",", local.resource_scopes)
      IDENTITY_PROVIDERS    = join(",", local.client_provider)
      REDIRECT_URI_PATTERNS = jsonencode(var.redirect_uri_allow_patterns)
    }
  }

  depends_on = [aws_cloudwatch_log_group.dcr]
}

resource "aws_lambda_permission" "api" {
  statement_id  = "AllowApiGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.dcr.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/*/*"
}
