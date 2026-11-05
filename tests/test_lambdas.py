"""Unit tests for the two Lambda functions. Run from the repository root:

    python -m unittest discover -s tests -v

They need only Python and boto3 (no AWS access: the AWS clients are mocked).
"""

import importlib.util
import json
import os
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parent.parent


def load(name, relative_path, env):
    """Import a Lambda file with the environment variables it reads at import time."""
    for key, value in env.items():
        os.environ[key] = value
    spec = importlib.util.spec_from_file_location(name, ROOT / relative_path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


signup = load(
    "signup",
    "lambda/signup/index.py",
    {"ALLOWED_EMAIL_DOMAINS": "example.com", "TRUSTED_PROVIDERS": "CompanySAML"},
)
# The AWS clients are replaced by mocks: the tests never call AWS (and old boto3 versions do not know the AgentCore service).
with mock.patch("boto3.client"):
    dcr = load(
        "dcr",
        "lambda/dcr/index.py",
        {
            "AWS_DEFAULT_REGION": "us-east-1",
            "USER_POOL_ID": "us-east-1_TEST",
            "GATEWAY_NAME": "test-gateway",
            "RESOURCE_SCOPES": "mcp/read,mcp/write",
            "REDIRECT_URI_PATTERNS": json.dumps(["^https://claude\\.ai/api/mcp/auth_callback$", "^http://localhost(:[0-9]+)?(/.*)?$"]),
        },
    )


def signup_event(source, username, email, verified, identities=None):
    attributes = {"email": email, "email_verified": verified}
    if identities is not None:
        attributes["identities"] = json.dumps(identities)
    return {"triggerSource": source, "userName": username, "request": {"userAttributes": attributes}}


class SignupCheck(unittest.TestCase):
    def allowed(self, event):
        try:
            signup.handler(event, None)
            return True
        except Exception:
            return False

    def test_verified_email_in_approved_domain_is_allowed(self):
        self.assertTrue(self.allowed(signup_event("PreSignUp_ExternalProvider", "Google_1", "a@example.com", "true")))

    def test_unverified_email_is_rejected(self):
        self.assertFalse(self.allowed(signup_event("PreSignUp_ExternalProvider", "Google_1", "a@example.com", "false")))

    def test_other_domain_is_rejected(self):
        self.assertFalse(self.allowed(signup_event("PreSignUp_ExternalProvider", "Google_1", "a@gmail.com", "true")))

    def test_missing_email_is_rejected(self):
        self.assertFalse(self.allowed(signup_event("PreSignUp_ExternalProvider", "Google_1", "", "true")))

    def test_trusted_saml_provider_may_have_unverified_flag(self):
        event = signup_event("PreSignUp_ExternalProvider", "CompanySAML_a@example.com", "a@example.com", "false")
        self.assertTrue(self.allowed(event))

    def test_trusted_saml_provider_still_needs_approved_domain(self):
        event = signup_event("PreSignUp_ExternalProvider", "CompanySAML_a@gmail.com", "a@gmail.com", "false")
        self.assertFalse(self.allowed(event))

    def test_token_time_uses_identities_for_trusted_provider(self):
        identities = [{"providerName": "CompanySAML", "providerType": "SAML"}]
        event = signup_event("TokenGeneration_Authentication", "CompanySAML_x", "a@example.com", "false", identities)
        self.assertTrue(self.allowed(event))

    def test_native_user_cannot_pretend_to_be_a_trusted_provider(self):
        # No identities attribute: a user simply named like the provider gets no special treatment.
        event = signup_event("TokenGeneration_Authentication", "CompanySAML_evil", "a@example.com", "false")
        self.assertFalse(self.allowed(event))
        event = signup_event("PreSignUp_SignUp", "CompanySAML_evil", "a@example.com", "false")
        self.assertFalse(self.allowed(event))


class RedirectUris(unittest.TestCase):
    def test_known_callbacks_are_accepted(self):
        self.assertTrue(dcr.valid_redirect_uris(["https://claude.ai/api/mcp/auth_callback"]))
        self.assertTrue(dcr.valid_redirect_uris(["http://localhost:33418/callback"]))

    def test_unknown_callback_is_rejected(self):
        self.assertFalse(dcr.valid_redirect_uris(["https://evil.example.com/cb"]))
        self.assertFalse(dcr.valid_redirect_uris(["https://claude.ai/api/mcp/auth_callback", "https://evil.example.com/cb"]))

    def test_empty_or_wrong_type_is_rejected(self):
        self.assertFalse(dcr.valid_redirect_uris([]))
        self.assertFalse(dcr.valid_redirect_uris(None))
        self.assertFalse(dcr.valid_redirect_uris("https://claude.ai/api/mcp/auth_callback"))

    def test_empty_pattern_list_refuses_everything(self):
        original = dcr.REDIRECT_PATTERNS
        dcr.REDIRECT_PATTERNS = []
        try:
            self.assertFalse(dcr.valid_redirect_uris(["https://claude.ai/api/mcp/auth_callback"]))
        finally:
            dcr.REDIRECT_PATTERNS = original


class RegisterHandler(unittest.TestCase):
    def test_bad_json_gets_400(self):
        result = dcr.handler({"body": "not json"}, None)
        self.assertEqual(result["statusCode"], 400)

    def test_bad_redirect_gets_400_and_creates_nothing(self):
        body = json.dumps({"client_name": "x", "redirect_uris": ["https://evil.example.com/cb"], "token_endpoint_auth_method": "none"})
        result = dcr.handler({"body": body}, None)
        self.assertEqual(result["statusCode"], 400)
        self.assertEqual(json.loads(result["body"])["error"], "invalid_redirect_uri")


if __name__ == "__main__":
    unittest.main()
