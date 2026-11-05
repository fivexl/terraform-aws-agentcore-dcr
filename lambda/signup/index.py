"""Cognito trigger: only allow people with an email in approved domains.

Used for two triggers:
- pre sign-up: when a user is created (for external providers, the first sign-in)
- pre token generation: every time tokens are issued or refreshed, so users that already exist
  (or were created by hand) are checked too

Users created by an administrator are allowed to be created, but they still need an approved
email to receive tokens.

Providers that report email_verified (Google, GitHub) must say it is true.
SAML providers listed in TRUSTED_PROVIDERS (the company's own login system) never send email_verified;
Cognito then fills in "false". For those providers the signed SAML answer is trusted and only the
email domain is checked.
"""

import json
import logging
import os

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ALLOWED_DOMAINS = [d.strip().lower() for d in os.environ.get("ALLOWED_EMAIL_DOMAINS", "").split(",") if d.strip()]
TRUSTED_PROVIDERS = [p.strip() for p in os.environ.get("TRUSTED_PROVIDERS", "").split(",") if p.strip()]

# Sign-up sources that are checked. Administrators who create users by hand are trusted at creation.
SIGN_UP_SOURCES = {"PreSignUp_ExternalProvider", "PreSignUp_SignUp"}


def provider_of(event, attributes):
    """Name of the trusted external provider this user came from, or None.

    - pre sign-up from an external provider: Cognito itself names the new user "<Provider>_<id>".
    - token generation: the user's "identities" attribute lists the provider (native users have none).
    """
    source = event.get("triggerSource", "")
    if source == "PreSignUp_ExternalProvider":
        username = event.get("userName", "")
        for name in TRUSTED_PROVIDERS:
            if username.startswith(name + "_"):
                return name
    elif source.startswith("TokenGeneration_"):
        try:
            identities = json.loads(attributes.get("identities") or "[]")
        except ValueError:
            identities = []
        for identity in identities:
            if identity.get("providerName") in TRUSTED_PROVIDERS:
                return identity["providerName"]
    return None


def check(attributes, trusted_provider=None):
    """Raise unless the attributes contain an email in an approved domain (verified, unless the provider is trusted)."""
    email = (attributes.get("email") or "").strip().lower()
    if "@" not in email:
        logger.warning("Rejected: no email address")
        raise Exception("A verified email address is required to sign in.")

    domain = email.rsplit("@", 1)[1]

    # Providers that report an unverified address must not be trusted for a domain check,
    # unless the provider is one of the company's own SAML providers.
    verified = attributes.get("email_verified")
    if trusted_provider is None and verified is not None and str(verified).lower() != "true":
        logger.warning("Rejected: email not verified (domain %s)", domain)
        raise Exception("Your email address is not verified.")

    if domain not in ALLOWED_DOMAINS:
        logger.warning("Rejected: domain %s is not allowed", domain)
        raise Exception("Sign-in is limited to approved email domains.")

    if trusted_provider:
        logger.info("Allowed: domain %s (trusted provider %s)", domain, trusted_provider)
    else:
        logger.info("Allowed: domain %s", domain)


def handler(event, context):
    source = event.get("triggerSource", "")
    attributes = event.get("request", {}).get("userAttributes", {})

    if source.startswith("TokenGeneration_") or source in SIGN_UP_SOURCES:
        check(attributes, provider_of(event, attributes))

    return event
