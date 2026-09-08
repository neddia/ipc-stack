#!/usr/bin/env python3
"""Persist one-use enrollment before services start; preserve retries and old sites."""
import importlib.util
import json
import os
from pathlib import Path

spec=importlib.util.spec_from_file_location('identity_guard',Path(__file__).with_name('ensure-ipc-identity.py'))
guard=importlib.util.module_from_spec(spec);spec.loader.exec_module(guard)


def install(stack, secrets_dir, storage, cloud_url):
    source=Path(stack)/'cloud-enrollment.json'
    if not source.exists():return
    ticket=json.loads(source.read_text())
    if ticket['cloud_url'].rstrip('/')!=cloud_url.rstrip('/'):
        raise ValueError('Enrollment belongs to another cloud environment')
    storage=Path(storage);target=Path(secrets_dir)/'cloud.enrollment.json'
    if target.exists() and json.loads(target.read_text())!=ticket:
        raise ValueError('Another enrollment ticket already exists; do not reset device identity')
    if not target.exists():guard.atomic(target,json.dumps(ticket).encode())
    ipc=storage/'ipc';ipc.mkdir(parents=True,exist_ok=True)
    if not (ipc/'identity.json').exists() and not (ipc/'replacement.json').exists():
        guard.atomic(ipc/'enrollment-hold.json',json.dumps({'pending':True}).encode(),0o644)
    uid=int(os.getenv('SITE_AGENT_UID','1000'));gid=int(os.getenv('SITE_AGENT_GID','1000'))
    if os.geteuid()==0:
        for path in (target,ipc,ipc/'enrollment-hold.json'):
            if path.exists():os.chown(path,uid,gid)


if __name__=='__main__':
    import argparse
    parser=argparse.ArgumentParser()
    for name in ('stack','secrets','storage','cloud'):parser.add_argument('--'+name,required=True)
    args=parser.parse_args()
    try:install(args.stack,args.secrets,args.storage,args.cloud)
    except Exception as exc:raise SystemExit('Enrollment installation failed: '+type(exc).__name__) from None
