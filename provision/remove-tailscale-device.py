#!/usr/bin/env python3
"""Delete one controller from the tailnet by hostname, without logging secrets.

Uses the same OAuth client as mint-tailscale-auth-key.py (TS_API_CLIENT_ID and
TS_API_CLIENT_SECRET). The client needs the `devices:core` scope; without it this
exits non-zero and the caller says to remove the machine in the admin console.
"""

import base64
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request


def fail(message):
    print(f"remove-tailscale-device: {message}", file=sys.stderr)
    raise SystemExit(1)


def call(method, url, *, data=None, headers=None):
    request = urllib.request.Request(url, data=data, headers=headers or {}, method=method)
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            body = response.read()
    except urllib.error.HTTPError as exc:
        fail(f"Tailscale API {method} failed with HTTP {exc.code}")
    except (urllib.error.URLError, OSError) as exc:
        fail(f"Tailscale API connection failed: {exc}")
    try:
        return json.loads(body) if body else {}
    except (json.JSONDecodeError, UnicodeDecodeError):
        fail("Tailscale API returned invalid JSON")


if len(sys.argv) != 2 or not sys.argv[1].strip():
    fail("usage: remove-tailscale-device.py <hostname>")
hostname = sys.argv[1].strip().lower()
client_id = os.environ.get("TS_API_CLIENT_ID", "").strip()
client_secret = os.environ.get("TS_API_CLIENT_SECRET", "").strip()
if not client_id or not client_secret:
    fail("TS_API_CLIENT_ID and TS_API_CLIENT_SECRET are not set")
api_base = os.environ.get("TS_API_BASE_URL", "https://api.tailscale.com").rstrip("/")
tailnet = urllib.parse.quote(os.environ.get("TS_TAILNET", "-") or "-", safe="")

basic = base64.b64encode(f"{client_id}:{client_secret}".encode()).decode()
oauth = call("POST", f"{api_base}/api/v2/oauth/token",
             data=urllib.parse.urlencode({"grant_type": "client_credentials", "scope": "devices:core"}).encode(),
             headers={"Authorization": f"Basic {basic}", "Content-Type": "application/x-www-form-urlencoded"})
token = str(oauth.get("access_token") or "")
if not token:
    fail("OAuth response did not include an access token")
auth = {"Authorization": f"Bearer {token}"}

devices = call("GET", f"{api_base}/api/v2/tailnet/{tailnet}/devices", headers=auth).get("devices") or []
matches = [d for d in devices if str(d.get("hostname") or "").lower() == hostname
           or str(d.get("name") or "").lower().split(".")[0] == hostname]
if not matches:
    print(f"remove-tailscale-device: {hostname} is not on the tailnet")
    raise SystemExit(0)
if len(matches) > 1:
    fail(f"{len(matches)} machines are named {hostname}; remove the right one in the admin console")
call("DELETE", f"{api_base}/api/v2/device/{urllib.parse.quote(str(matches[0]['id']), safe='')}", headers=auth)
print(f"remove-tailscale-device: removed {hostname} from the tailnet")
