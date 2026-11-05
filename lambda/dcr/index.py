"""Dynamic client registration (RFC 7591) in front of Amazon Cognito.

Creates a Cognito app client for each registration request and adds it to the
allowed clients of the AgentCore Gateway.

The idea comes from stache-ai/agentcore-dcr (MIT, see NOTICE). This version
registers public clients when the caller asks for token_endpoint_auth_method
"none", checks redirect URIs against an allow list, does not log request
bodies, and rolls the client back if the Gateway cannot be updated.
"""

import json
import logging
import os
import random
import re
import time
import uuid

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

cognito = boto3.client("cognito-idp")
agentcore = boto3.client("bedrock-agentcore-control")

USER_POOL_ID = os.environ["USER_POOL_ID"]
GATEWAY_NAME = os.environ["GATEWAY_NAME"]
RESOURCE_SCOPES = [s for s in os.environ.get("RESOURCE_SCOPES", "").split(",") if s]
IDENTITY_PROVIDERS = [p for p in os.environ.get("IDENTITY_PROVIDERS", "COGNITO").split(",") if p]
REDIRECT_PATTERNS = [re.compile(p) for p in json.loads(os.environ.get("REDIRECT_URI_PATTERNS", "[]"))]

BASE_SCOPES = ["openid", "email", "phone", "profile"]
ALLOWED_SCOPES = BASE_SCOPES + RESOURCE_SCOPES

GATEWAY_UPDATE_ATTEMPTS = 4


def response(status_code, body):
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type": "application/json",
            "Cache-Control": "no-store",
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Headers": "Content-Type",
            "Access-Control-Allow-Methods": "POST, OPTIONS",
        },
        "body": json.dumps(body),
    }


def error(status_code, code, description):
    return response(status_code, {"error": code, "error_description": description})


def find_gateway_id(name):
    paginator = agentcore.get_paginator("list_gateways")
    for page in paginator.paginate():
        for gateway in page.get("items", []):
            if gateway.get("name") == name:
                return gateway.get("gatewayId")
    return None


def add_client_to_gateway(client_id):
    """Add the client to the Gateway's allowed clients, retrying on conflicts."""
    gateway_id = find_gateway_id(GATEWAY_NAME)
    if not gateway_id:
        raise RuntimeError(f"Gateway {GATEWAY_NAME!r} not found")

    for attempt in range(1, GATEWAY_UPDATE_ATTEMPTS + 1):
        gateway = agentcore.get_gateway(gatewayIdentifier=gateway_id)
        jwt_config = dict(gateway["authorizerConfiguration"]["customJWTAuthorizer"])
        jwt_config["allowedClients"] = sorted(set(jwt_config.get("allowedClients", [])) | {client_id})

        kwargs = {
            "gatewayIdentifier": gateway_id,
            "name": gateway["name"],
            "roleArn": gateway["roleArn"],
            "protocolType": gateway["protocolType"],
            "authorizerType": gateway["authorizerType"],
            "authorizerConfiguration": {"customJWTAuthorizer": jwt_config},
        }
        for key in ("description", "protocolConfiguration", "exceptionLevel", "kmsKeyArn"):
            if gateway.get(key):
                kwargs[key] = gateway[key]

        try:
            agentcore.update_gateway(**kwargs)
            return
        except ClientError as exc:
            code = exc.response.get("Error", {}).get("Code", "")
            if attempt < GATEWAY_UPDATE_ATTEMPTS and code in ("ConflictException", "ThrottlingException"):
                time.sleep(random.uniform(0.2, 0.8) * attempt)
                continue
            raise


def valid_redirect_uris(uris):
    if not isinstance(uris, list) or not uris:
        return False
    for uri in uris:
        if not isinstance(uri, str) or len(uri) > 2048:
            return False
        if REDIRECT_PATTERNS and not any(p.match(uri) for p in REDIRECT_PATTERNS):
            return False
    return True


def handler(event, context):
    try:
        body = json.loads(event.get("body") or "{}")
    except json.JSONDecodeError:
        return error(400, "invalid_client_metadata", "Body must be JSON.")
    if not isinstance(body, dict):
        return error(400, "invalid_client_metadata", "Body must be a JSON object.")

    # Cognito only accepts [\w\s+=,.@-]+ in client names. Claude Code sends
    # names with parentheses, so replace anything else.
    raw_name = body.get("client_name") or f"dcr-client-{uuid.uuid4().hex[:8]}"
    client_name = re.sub(r"[^\w\s+=,.@-]", "-", str(raw_name))[:128]

    redirect_uris = body.get("redirect_uris")
    if not valid_redirect_uris(redirect_uris):
        # Redirect URIs are not secret; log them so the allow list can be fixed for new clients.
        logger.warning("Rejected redirect_uris for client %r: %s", client_name, json.dumps(redirect_uris)[:500])
        return error(400, "invalid_redirect_uri", "redirect_uris must be a non-empty list of allowed URIs.")

    public_client = body.get("token_endpoint_auth_method") == "none"

    requested = [s for s in str(body.get("scope", "")).split() if s]
    scopes = [s for s in requested if s in ALLOWED_SCOPES] or ALLOWED_SCOPES

    try:
        created = cognito.create_user_pool_client(
            UserPoolId=USER_POOL_ID,
            ClientName=client_name,
            GenerateSecret=not public_client,
            ExplicitAuthFlows=["ALLOW_REFRESH_TOKEN_AUTH", "ALLOW_USER_SRP_AUTH"],
            AllowedOAuthFlows=["code"],
            AllowedOAuthScopes=scopes,
            AllowedOAuthFlowsUserPoolClient=True,
            CallbackURLs=redirect_uris,
            SupportedIdentityProviders=IDENTITY_PROVIDERS,
        )["UserPoolClient"]
    except ClientError as exc:
        code = exc.response.get("Error", {}).get("Code", "")
        if code == "InvalidParameterException":
            return error(400, "invalid_client_metadata", "Cognito rejected the client metadata.")
        logger.error("create_user_pool_client failed: %s", code)
        return error(500, "server_error", "Client registration failed.")

    client_id = created["ClientId"]

    try:
        add_client_to_gateway(client_id)
    except Exception as exc:  # roll back so no unusable client is left behind
        logger.error("Could not add %s to the gateway (%s); deleting the client", client_id, type(exc).__name__)
        try:
            cognito.delete_user_pool_client(UserPoolId=USER_POOL_ID, ClientId=client_id)
        except ClientError:
            logger.error("Rollback failed for %s", client_id)
        return error(500, "server_error", "Client registration failed.")

    logger.info("Registered client %s (%s, %s)", client_id, client_name, "public" if public_client else "confidential")

    result = {
        "client_id": client_id,
        "client_id_issued_at": int(time.time()),
        "client_name": client_name,
        "redirect_uris": redirect_uris,
        "grant_types": ["authorization_code", "refresh_token"],
        "response_types": ["code"],
        "token_endpoint_auth_method": "none" if public_client else "client_secret_basic",
        "scope": " ".join(scopes),
    }
    if not public_client:
        result["client_secret"] = created["ClientSecret"]
    return response(201, result)
