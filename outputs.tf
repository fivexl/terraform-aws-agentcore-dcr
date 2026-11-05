output "gateway_id" {
  description = "ID of the AgentCore Gateway."
  value       = aws_bedrockagentcore_gateway.this.gateway_id
}

output "gateway_arn" {
  description = "ARN of the AgentCore Gateway."
  value       = aws_bedrockagentcore_gateway.this.gateway_arn
}

output "gateway_mcp_url" {
  description = "Address to add as an MCP server or custom connector (Claude, Cursor, ...)."
  value       = "https://${aws_bedrockagentcore_gateway.this.gateway_id}.gateway.bedrock-agentcore.${local.region}.amazonaws.com/mcp"
}

output "oidc_discovery_url" {
  description = "Login description the Gateway and clients read."
  value       = "${local.api_base}/.well-known/openid-configuration"
}

output "dcr_endpoint" {
  description = "Dynamic client registration endpoint (open to the internet; protect or remove when not testing)."
  value       = "${local.api_base}/register"
}

output "user_pool_id" {
  description = "Cognito user pool ID."
  value       = local.user_pool_id
}

output "cognito_domain_host" {
  description = "Hosted login host of the user pool."
  value       = local.cognito_host
}

output "initial_client_id" {
  description = "ID of the first Cognito app client."
  value       = aws_cognito_user_pool_client.initial.id
}

output "dcr_lambda_name" {
  description = "Name of the registration function (useful for reading its logs)."
  value       = aws_lambda_function.dcr.function_name
}
