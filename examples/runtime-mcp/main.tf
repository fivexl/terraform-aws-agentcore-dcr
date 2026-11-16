# Example: an MCP server hosted in AgentCore Runtime, reached through the DCR gateway.
#
# People log in through the gateway (Cognito, dynamic client registration, groups). The gateway then calls the
# MCP server in Runtime with its own IAM role (SigV4), so the Runtime is not reachable by anyone else.
# Status: draft, not deployed yet. See README.md.

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

data "aws_caller_identity" "current" {}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "name_prefix" {
  description = "Prefix for resource names. Letters, digits and hyphens."
  type        = string
  default     = "rt"
}

variable "cognito_domain_prefix" {
  description = "Unique prefix for the Cognito hosted login domain (no 'aws', 'amazon' or 'cognito' in it)."
  type        = string
}

variable "owner_tag" {
  type    = string
  default = "example"
}

variable "runtime_python" {
  description = "Python version of the Runtime. Must match the version used in build.py."
  type        = string
  default     = "PYTHON_3_13"
}

variable "runtime_platform_version" {
  description = "AgentCore Runtime generation: V2 scales to zero and starts in about 2 seconds."
  type        = string
  default     = "V2"
}

locals {
  tags = {
    owner   = var.owner_tag
    purpose = "agentcore-dcr-runtime-example"
  }
  runtime_name = replace("${var.name_prefix}_mcp_server", "-", "_")
}

# The tool the gateway already needs (a Lambda target stays in the module for now).
data "archive_file" "tool" {
  type        = "zip"
  source_dir  = "${path.module}/tool"
  output_path = "${path.module}/.build/tool.zip"
}

data "aws_iam_policy_document" "lambda_assume" {
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
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
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

module "agentcore_dcr" {
  source = "../.."

  name_prefix           = var.name_prefix
  cognito_domain_prefix = var.cognito_domain_prefix
  tool_lambda_arn       = aws_lambda_function.tool.arn
  tags                  = local.tags
}

# --- The MCP server in AgentCore Runtime -------------------------------------------------------------------------

resource "aws_s3_bucket" "code" {
  bucket_prefix = "${var.name_prefix}-mcp-code-"
  force_destroy = true
  tags          = local.tags
}

resource "aws_s3_bucket_public_access_block" "code" {
  bucket                  = aws_s3_bucket.code.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Build it first with: python build.py
resource "aws_s3_object" "code" {
  bucket      = aws_s3_bucket.code.id
  key         = "server.zip"
  source      = "${path.module}/.build/server.zip"
  source_hash = filemd5("${path.module}/.build/server.zip")
}

data "aws_iam_policy_document" "runtime_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["bedrock-agentcore.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_iam_role" "runtime" {
  name               = "${var.name_prefix}-mcp-runtime-role"
  assume_role_policy = data.aws_iam_policy_document.runtime_assume.json
  tags               = local.tags
}

# Minimal permissions: read the code and write logs. Add more only when the server needs them.
resource "aws_iam_role_policy" "runtime" {
  name = "runtime"
  role = aws_iam_role.runtime.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.code.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:${var.region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/bedrock-agentcore/runtimes/*"
      },
    ]
  })
}

resource "aws_bedrockagentcore_agent_runtime" "mcp" {
  agent_runtime_name = local.runtime_name
  description        = "Example MCP server behind the DCR gateway"
  role_arn           = aws_iam_role.runtime.arn
  platform_version   = var.runtime_platform_version
  tags               = local.tags

  agent_runtime_artifact {
    code_configuration {
      entry_point = ["main.py"]
      runtime     = var.runtime_python

      code {
        s3 {
          bucket = aws_s3_bucket.code.id
          prefix = aws_s3_object.code.key
        }
      }
    }
  }

  network_configuration {
    network_mode = "PUBLIC"
  }

  protocol_configuration {
    server_protocol = "MCP"
  }

  # No authorizer block: callers must sign requests with IAM (SigV4). Only the gateway's role is allowed below.

  depends_on = [aws_iam_role_policy.runtime]
}

# --- The gateway reaches the Runtime with its own IAM role -------------------------------------------------------

resource "aws_iam_role_policy" "gateway_invoke_runtime" {
  name = "invoke-mcp-runtime"
  role = module.agentcore_dcr.gateway_role_name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["bedrock-agentcore:InvokeAgentRuntime"]
      Resource = [
        aws_bedrockagentcore_agent_runtime.mcp.agent_runtime_arn,
        "${aws_bedrockagentcore_agent_runtime.mcp.agent_runtime_arn}/runtime-endpoint/*",
      ]
    }]
  })
}

resource "aws_bedrockagentcore_gateway_target" "runtime_mcp" {
  gateway_identifier = module.agentcore_dcr.gateway_id
  name               = "runtime-mcp"
  description        = "MCP server hosted in AgentCore Runtime"

  credential_provider_configuration {
    gateway_iam_role {
      service = "bedrock-agentcore"
    }
  }

  target_configuration {
    mcp {
      mcp_server {
        endpoint = "https://bedrock-agentcore.${var.region}.amazonaws.com/runtimes/${urlencode(aws_bedrockagentcore_agent_runtime.mcp.agent_runtime_arn)}/invocations?qualifier=DEFAULT"
      }
    }
  }

  depends_on = [aws_iam_role_policy.gateway_invoke_runtime]
}

output "gateway_mcp_url" {
  value = module.agentcore_dcr.gateway_mcp_url
}

output "runtime_arn" {
  value = aws_bedrockagentcore_agent_runtime.mcp.agent_runtime_arn
}
