"""Cognito trigger: only allow people from approved email domains and approved groups.

Used for two triggers:
- pre sign-up: when a user is created (for external providers, the first sign-in)
- pre token generation: every time tokens are issued or refreshed, so users that already exist
  (or were created by hand) are checked too

Users created by an administrator are allowed to be created, but they still need to pass the checks
to receive tokens.

Email domain (ALLOWED_EMAIL_DOMAINS, optional):
  Providers that report email_verified (Google, GitHub) must say it is true.
  SAML providers listed in TRUSTED_PROVIDERS (the company's own login system) never send email_verified;
  Cognito then fills in "false". For those providers the signed SAML answer is trusted and only the
  email domain is checked.

Groups (ALLOWED_GROUPS, optional):
  The person must belong to at least one of the groups. Groups arrive from the identity provider in the
  custom attribute custom:groups (the module maps the SAML groups attribute to it). The check runs when
  tokens are issued. At sign-up it only runs when the attribute is present, because Cognito may not hand
  mapped attributes to that trigger. When tokens are issued, the person's groups are also written into the
  cognito:groups claim of the ID and access token, so the gateway and other services can use them.
  Providers that send no groups (plain Google login, GitHub, Cognito users) are refused while groups are required.
"""

import json
import logging
import os

logger = logging.getLogger()
logger.setLevel(logging.INFO)

ALLOWED_DOMAINS = [d.strip().lower() for d in os.environ.get("ALLOWED_EMAIL_DOMAINS", "").split(",") if d.strip()]
ALLOWED_GROUPS = [g.strip() for g in os.environ.get("ALLOWED_GROUPS", "").split(",") if g.strip()]
TRUSTED_PROVIDERS = [p.strip() for p in os.environ.get("TRUSTED_PROVIDERS", "").split(",") if p.strip()]

# Sign-up sources that are checked. Administrators who create users by hand are trusted at creation.
SIGN_UP_SOURCES = {"PreSignUp_ExternalProvider", "PreSignUp_SignUp"}

GROUPS_ATTRIBUTE = "custom:groups"


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


def parse_groups(value):
    """Turn the stored attribute into a list of group names.

    SAML sends one value per group. Cognito stores them in one string; depending on how, that string is a JSON
    list (["a","b"]) or a list separated by commas, semicolons or line breaks. All of these are accepted.
    """
    if value is None:
        return []
    text = str(value).strip()
    if not text:
        return []
    if text.startswith("["):
        try:
            parsed = json.loads(text)
            if isinstance(parsed, list):
                return [str(g).strip() for g in parsed if str(g).strip()]
        except ValueError:
            text = text.strip("[]")
    for separator in (";", "\n"):
        text = text.replace(separator, ",")
    return [g.strip().strip('"').strip("'") for g in text.split(",") if g.strip().strip('"').strip("'")]


def in_allowed_group(groups):
    """True when at least one group matches an allowed group (ignoring case; a group address matches its name)."""
    allowed = {g.lower() for g in ALLOWED_GROUPS}
    for group in groups:
        low = group.lower()
        if low in allowed or low.split("@", 1)[0] in allowed:
            return True
    return False


def check_email(attributes, trusted_provider=None):
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


def check_groups(attributes, at_token_time):
    """Raise unless the person is in an approved group. Returns the person's groups."""
    present = GROUPS_ATTRIBUTE in attributes
    groups = parse_groups(attributes.get(GROUPS_ATTRIBUTE))

    if not at_token_time and not present:
        # Sign-up without the attribute: decide when tokens are issued instead.
        logger.info("Groups not present at sign-up; checked when tokens are issued")
        return groups

    if not groups:
        logger.warning("Rejected: no groups received from the identity provider")
        raise Exception("Sign-in is limited to approved groups.")

    if not in_allowed_group(groups):
        logger.warning("Rejected: not in an approved group (groups received: %s)", ", ".join(groups))
        raise Exception("Sign-in is limited to approved groups.")

    logger.info("Allowed: in an approved group (groups received: %s)", ", ".join(groups))
    return groups


def handler(event, context):
    source = event.get("triggerSource", "")
    attributes = event.get("request", {}).get("userAttributes", {})
    at_token_time = source.startswith("TokenGeneration_")

    if not (at_token_time or source in SIGN_UP_SOURCES):
        return event

    if ALLOWED_DOMAINS:
        check_email(attributes, provider_of(event, attributes))

    groups = []
    if ALLOWED_GROUPS:
        groups = check_groups(attributes, at_token_time)
    elif at_token_time:
        groups = parse_groups(attributes.get(GROUPS_ATTRIBUTE))

    # Put the person's groups into the cognito:groups claim of the ID and access token.
    if at_token_time and groups:
        event["response"] = {"claimsOverrideDetails": {"groupOverrideDetails": {"groupsToOverride": groups}}}

    return event
