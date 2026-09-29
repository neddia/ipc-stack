#!/usr/bin/env python3
"""Mint one tagged, single-use Tailscale auth key without logging secrets."""

import base64
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request


def fail(message):
    print(f"mint-tailscale-auth-key: {message}", file=sys.stderr)
    raise SystemExit(1)


def post_json(url, data, headers):
    request = urllib.request.Request(url, data=data, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            result = json.loads(response.read())
    except urllib.error.HTTPError as exc:
        fail(f"Tailscale API request failed with HTTP {exc.code}")
    except urllib.error.URLError as exc:
        fail(f"Tailscale API request failed: {exc.reason}")
    except (json.JSONDecodeError, UnicodeDecodeError):
        fail("Tailscale API returned invalid JSON")
    except OSError as exc:
        fail(f"Tailscale API connection failed: {exc}")
    if not isinstance(result, dict):
        fail("Tailscale API returned an unexpected response")
    return result


client_id = os.environ.get("TS_API_CLIENT_ID", "").strip()
client_secret = os.environ.get("TS_API_CLIENT_SECRET", "").strip()
hostname = os.environ.get("TS_HOSTNAME", "").strip()
if not client_id or not client_secret or not hostname:
    fail("TS_API_CLIENT_ID, TS_API_CLIENT_SECRET, and TS_HOSTNAME are required")

tags = [value.strip() for value in os.environ.get("TS_TAGS", "tag:ipc").split(",") if value.strip()]
if not tags or any(not value.startswith("tag:") for value in tags):
    fail("TS_TAGS must be a comma-separated list of tag: values")
# Keys are not pre-approved: with device approval enabled on the tailnet, a
# node that uses one waits for an operator to approve it. Customer hardware may
# not be installed the day its media is built, so keys last a week by default.
preauthorized = os.environ.get("TS_PREAUTHORIZED", "0").strip() == "1"
# Ephemeral nodes disappear once offline; for qualification runs only.
ephemeral = os.environ.get("TS_EPHEMERAL", "0").strip() == "1"
try:
    expiry_seconds = int(os.environ.get("TS_AUTHKEY_EXPIRY_SECONDS", "604800"))
except ValueError:
    fail("TS_AUTHKEY_EXPIRY_SECONDS must be a whole number of seconds")
if not 3600 <= expiry_seconds <= 90 * 86400:
    fail("TS_AUTHKEY_EXPIRY_SECONDS must be between one hour and 90 days")
api_base = os.environ.get("TS_API_BASE_URL", "https://api.tailscale.com").rstrip("/")
basic = base64.b64encode(f"{client_id}:{client_secret}".encode()).decode()
oauth = post_json(
    f"{api_base}/api/v2/oauth/token",
    urllib.parse.urlencode(
        {"grant_type": "client_credentials", "scope": "auth_keys", "tags": " ".join(tags)}
    ).encode(),
    {"Authorization": f"Basic {basic}", "Content-Type": "application/x-www-form-urlencoded"},
)
access_token = str(oauth.get("access_token") or "")
if not access_token:
    fail("OAuth response did not include an access token")

key_response = post_json(
    f"{api_base}/api/v2/tailnet/{urllib.parse.quote(os.environ.get('TS_TAILNET', '-') or '-', safe='')}/keys",
    json.dumps(
        {
            "capabilities": {"devices": {"create": {
                "reusable": False,
                "ephemeral": ephemeral,
                "preauthorized": preauthorized,
                "tags": tags,
            }}},
            "expirySeconds": expiry_seconds,
            "description": f"Toops provisioning {hostname}",
        }
    ).encode(),
    {"Authorization": f"Bearer {access_token}", "Content-Type": "application/json"},
)
auth_key = str(key_response.get("key") or "")
if not auth_key:
    fail("auth-key response did not include a key")
print(auth_key, end="")
