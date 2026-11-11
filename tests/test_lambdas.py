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


def group_event(source, username, groups_value, email="a@example.com", verified="false", identities=None, with_attr=True):
    attributes = {"email": email, "email_verified": verified}
    if with_attr:
        attributes["custom:groups"] = groups_value
    if identities is not None:
        attributes["identities"] = json.dumps(identities)
    return {"triggerSource": source, "userName": username, "request": {"userAttributes": attributes}, "response": {}}


SAML_IDENTITY = [{"providerName": "CompanySAML", "providerType": "SAML"}]


class GroupParsing(unittest.TestCase):
    def test_json_list(self):
        self.assertEqual(signup.parse_groups('["dev","ops"]'), ["dev", "ops"])

    def test_comma_semicolon_and_line_break_lists(self):
        self.assertEqual(signup.parse_groups("dev,ops"), ["dev", "ops"])
        self.assertEqual(signup.parse_groups("dev; ops"), ["dev", "ops"])
        self.assertEqual(signup.parse_groups("dev\nops"), ["dev", "ops"])

    def test_single_value_and_empty(self):
        self.assertEqual(signup.parse_groups("dev"), ["dev"])
        self.assertEqual(signup.parse_groups(""), [])
        self.assertEqual(signup.parse_groups(None), [])

    def test_broken_json_still_gives_names(self):
        self.assertEqual(signup.parse_groups('["dev","ops"'), ["dev", "ops"])


class GroupCheck(unittest.TestCase):
    def setUp(self):
        # Groups required; the email domain check stays on as in a normal setup.
        patches = [
            mock.patch.object(signup, "ALLOWED_GROUPS", ["developers"]),
            mock.patch.object(signup, "ALLOWED_DOMAINS", ["example.com"]),
        ]
        for p in patches:
            p.start()
            self.addCleanup(p.stop)

    def run_event(self, event):
        try:
            return signup.handler(event, None)
        except Exception as exc:  # the trigger refuses by raising
            return exc

    def test_token_time_member_is_allowed_and_groups_go_into_the_claim(self):
        event = group_event("TokenGeneration_Authentication", "CompanySAML_x", '["developers","other"]', identities=SAML_IDENTITY)
        result = self.run_event(event)
        self.assertNotIsInstance(result, Exception)
        override = result["response"]["claimsOverrideDetails"]["groupOverrideDetails"]["groupsToOverride"]
        self.assertEqual(override, ["developers", "other"])

    def test_token_time_non_member_is_refused(self):
        event = group_event("TokenGeneration_Authentication", "CompanySAML_x", '["marketing"]', identities=SAML_IDENTITY)
        self.assertIsInstance(self.run_event(event), Exception)

    def test_token_time_without_groups_is_refused(self):
        # For example a plain Google login or GitHub: no groups attribute at all.
        event = group_event("TokenGeneration_Authentication", "Google_1", "", verified="true", with_attr=False)
        self.assertIsInstance(self.run_event(event), Exception)

    def test_matching_ignores_case_and_accepts_a_group_address(self):
        for value in ("Developers", "developers@example.com", '["DEVELOPERS@example.com"]'):
            event = group_event("TokenGeneration_Authentication", "CompanySAML_x", value, identities=SAML_IDENTITY)
            self.assertNotIsInstance(self.run_event(event), Exception, value)

    def test_a_similar_name_does_not_match(self):
        event = group_event("TokenGeneration_Authentication", "CompanySAML_x", "developers-external", identities=SAML_IDENTITY)
        self.assertIsInstance(self.run_event(event), Exception)

    def test_sign_up_without_the_attribute_is_deferred_to_token_time(self):
        event = group_event("PreSignUp_ExternalProvider", "CompanySAML_x", "", with_attr=False)
        self.assertNotIsInstance(self.run_event(event), Exception)

    def test_sign_up_with_the_attribute_is_checked(self):
        refused = group_event("PreSignUp_ExternalProvider", "CompanySAML_x", '["marketing"]')
        self.assertIsInstance(self.run_event(refused), Exception)
        allowed = group_event("PreSignUp_ExternalProvider", "CompanySAML_x", '["developers"]')
        self.assertNotIsInstance(self.run_event(allowed), Exception)

    def test_the_email_domain_check_still_applies(self):
        event = group_event("TokenGeneration_Authentication", "CompanySAML_x", '["developers"]', email="a@gmail.com", identities=SAML_IDENTITY)
        self.assertIsInstance(self.run_event(event), Exception)


class GroupsOnly(unittest.TestCase):
    """Groups required, no email domain list: the email must not be demanded."""

    def test_no_email_needed_when_only_groups_are_configured(self):
        with mock.patch.object(signup, "ALLOWED_GROUPS", ["developers"]), mock.patch.object(signup, "ALLOWED_DOMAINS", []):
            event = {
                "triggerSource": "TokenGeneration_Authentication",
                "userName": "CompanySAML_x",
                "request": {"userAttributes": {"custom:groups": "developers"}},
                "response": {},
            }
            result = signup.handler(event, None)
            self.assertEqual(result["response"]["claimsOverrideDetails"]["groupOverrideDetails"]["groupsToOverride"], ["developers"])


class GroupsWithoutRestriction(unittest.TestCase):
    def test_groups_are_still_written_into_the_token_when_nothing_is_required(self):
        with mock.patch.object(signup, "ALLOWED_GROUPS", []), mock.patch.object(signup, "ALLOWED_DOMAINS", ["example.com"]):
            event = group_event("TokenGeneration_Authentication", "CompanySAML_x", '["ops"]', identities=SAML_IDENTITY)
            result = signup.handler(event, None)
            self.assertEqual(result["response"]["claimsOverrideDetails"]["groupOverrideDetails"]["groupsToOverride"], ["ops"])

    def test_nothing_changes_without_groups(self):
        with mock.patch.object(signup, "ALLOWED_GROUPS", []), mock.patch.object(signup, "ALLOWED_DOMAINS", ["example.com"]):
            event = group_event("TokenGeneration_Authentication", "CompanySAML_x", "", identities=SAML_IDENTITY, with_attr=False)
            result = signup.handler(event, None)
            self.assertEqual(result["response"], {})


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
