data "aws_iam_policy_document" "gateway_assume" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["bedrock-agentcore.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:bedrock-agentcore:${local.region}:${local.account_id}:gateway/*"]
    }
  }
}

resource "aws_iam_role" "gateway" {
  name               = "${var.name_prefix}-agentcore-gateway-role"
  assume_role_policy = data.aws_iam_policy_document.gateway_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "gateway_invoke_tool" {
  name = "invoke-tool-lambda"
  role = aws_iam_role.gateway.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = "lambda:InvokeFunction"
      Resource = var.tool_lambda_arn
    }]
  })
}

resource "aws_bedrockagentcore_gateway" "this" {
  name            = local.gateway_name
  description     = "MCP gateway with dynamic client registration"
  role_arn        = aws_iam_role.gateway.arn
  protocol_type   = "MCP"
  authorizer_type = "CUSTOM_JWT"
  tags            = var.tags

  authorizer_configuration {
    custom_jwt_authorizer {
      # The Gateway reads this document when it is created, so the API stage must exist first.
      discovery_url = "${local.api_base}/.well-known/openid-configuration"
      allowed_clients = [
        aws_cognito_user_pool_client.initial.id,
      ]

      # Optional second check: the token's cognito:groups claim must contain one of the allowed groups.
      dynamic "custom_claim" {
        for_each = var.require_groups_at_gateway && length(var.allowed_groups) > 0 ? [1] : []
        content {
          inbound_token_claim_name       = "cognito:groups"
          inbound_token_claim_value_type = "STRING_ARRAY"

          authorizing_claim_match_value {
            claim_match_operator = "CONTAINS_ANY"

            claim_match_value {
              match_value_string_list = var.allowed_groups
            }
          }
        }
      }
    }
  }

  # The registration function adds clients to this list at run time.
  lifecycle {
    ignore_changes = [authorizer_configuration[0].custom_jwt_authorizer[0].allowed_clients]
  }

  depends_on = [
    aws_api_gateway_stage.this,
    aws_iam_role_policy.gateway_invoke_tool,
  ]
}

resource "aws_bedrockagentcore_gateway_target" "tool" {
  name               = "${var.name_prefix}-mcp-target"
  description        = "Tool Lambda"
  gateway_identifier = aws_bedrockagentcore_gateway.this.gateway_id

  credential_provider_configuration {
    gateway_iam_role {}
  }

  target_configuration {
    mcp {
      lambda {
        lambda_arn = var.tool_lambda_arn

        tool_schema {
          dynamic "inline_payload" {
            for_each = var.tools
            content {
              name        = inline_payload.value.name
              description = inline_payload.value.description

              input_schema {
                type = "object"

                dynamic "property" {
                  for_each = inline_payload.value.properties
                  content {
                    name        = property.value.name
                    type        = property.value.type
                    description = property.value.description
                    required    = property.value.required
                  }
                }
              }
            }
          }
        }
      }
    }
  }
}

# Attached after the Gateway exists, so the permissions can name it (see dcr_lambda.tf).
data "aws_iam_policy_document" "dcr_gateway" {
  statement {
    actions   = ["bedrock-agentcore:GetGateway", "bedrock-agentcore:UpdateGateway"]
    resources = [aws_bedrockagentcore_gateway.this.gateway_arn]
  }

  statement {
    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.gateway.arn]
  }
}

resource "aws_iam_role_policy" "dcr_gateway" {
  name   = "update-gateway"
  role   = aws_iam_role.dcr.id
  policy = data.aws_iam_policy_document.dcr_gateway.json
}
