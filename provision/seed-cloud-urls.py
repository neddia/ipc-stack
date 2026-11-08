#!/usr/bin/env python3
"""Print the seed's cloud addresses as JSON: the API from the ticket, the browser link from the installer.

Controllers call CLOUD_BASE_URL (the infrastructure name in the ticket). Links a
person clicks use CLOUD_PUBLIC_BASE_URL, the address the installer credential was
downloaded from. Older credentials without public_url use the API address.
"""
import json
import os
import sys


def seed_urls(ticket_path, installer_path, override=None):
    api = str(json.load(open(ticket_path))['cloud_url']).rstrip('/')
    if override and override.rstrip('/') != api:
        raise ValueError('Cloud override conflicts with installer authorization')
    public = str(json.load(open(installer_path)).get('public_url') or api).rstrip('/')
    if not public.startswith('https://') and api.startswith('https://'):
        raise ValueError('Installer public_url must use https://')
    return {'CLOUD_BASE_URL': api, 'CLOUD_PUBLIC_BASE_URL': public}


if __name__ == '__main__':
    if len(sys.argv) != 3:
        raise SystemExit('usage: seed-cloud-urls.py <cloud-enrollment.json> <installer config>')
    try:
        print(json.dumps(seed_urls(sys.argv[1], sys.argv[2], os.environ.get('IPC_E2E_CLOUD_BASE_URL'))))
    except (OSError, KeyError, ValueError) as exc:
        raise SystemExit('seed-cloud-urls: ' + str(exc)) from None
