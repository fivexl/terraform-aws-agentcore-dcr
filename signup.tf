# Optional authorization at sign-in: only people whose verified email belongs to an
# approved domain can be created in the user pool. Needs create_user_pool = true.
# For an existing pool, set this trigger up yourself (see docs).
locals {
  restrict_domains = length(var.allowed_email_domains) > 0 && var.create_user_pool
}

data "archive_file" "signup" {
  count = local.restrict_domains ? 1 : 0

  type        = "zip"
  source_dir  = "${path.module}/lambda/signup"
  output_path = "${path.module}/.build/signup.zip"
}

resource "aws_cloudwatch_log_group" "signup" {
  count = local.restrict_domains ? 1 : 0

  name              = "/aws/lambda/${var.name_prefix}-signup-domain-check"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_iam_role" "signup" {
  count = local.restrict_domains ? 1 : 0

  name               = "${var.name_prefix}-signup-domain-check-role"
  assume_role_policy = data.aws_iam_policy_document.dcr_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "signup_logs" {
  count = local.restrict_domains ? 1 : 0

  name = "logs"
  role = aws_iam_role.signup[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
      Resource = "${aws_cloudwatch_log_group.signup[0].arn}:*"
    }]
  })
}

resource "aws_lambda_function" "signup_domain" {
  count = local.restrict_domains ? 1 : 0

  function_name    = "${var.name_prefix}-signup-domain-check"
  role             = aws_iam_role.signup[0].arn
  runtime          = "python3.12"
  handler          = "index.handler"
  timeout          = 5
  filename         = data.archive_file.signup[0].output_path
  source_code_hash = data.archive_file.signup[0].output_base64sha256
  tags             = var.tags

  environment {
    variables = {
      ALLOWED_EMAIL_DOMAINS = join(",", var.allowed_email_domains)
      # SAML providers are the company's own login systems: they never send email_verified.
      TRUSTED_PROVIDERS = join(",", keys(var.saml_providers))
    }
  }

  depends_on = [aws_cloudwatch_log_group.signup]
}

resource "aws_lambda_permission" "signup_cognito" {
  count = local.restrict_domains ? 1 : 0

  statement_id  = "AllowCognitoInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.signup_domain[0].function_name
  principal     = "cognito-idp.amazonaws.com"
  source_arn    = aws_cognito_user_pool.this[0].arn
}
