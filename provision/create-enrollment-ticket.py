#!/usr/bin/env python3
"""Build-machine only. Never copy the installer credential into an IPC image."""
import argparse
import json
import os
from pathlib import Path
import secrets
import stat
import urllib.request
from urllib.parse import urlsplit
from uuid import uuid4


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,*args,**kwargs):return None


def create(config_path, output_path, name):
    path=Path(config_path)
    if stat.S_IMODE(path.stat().st_mode)!=0o600:raise ValueError('Installer configuration must have mode 600')
    config=json.loads(path.read_text())
    base=str(config['cloud_url']).rstrip('/')
    parts=urlsplit(base)
    if parts.scheme!='https' or not parts.netloc or parts.username or parts.password or parts.query or parts.fragment:
        raise ValueError('HTTPS cloud URL required')
    destination=Path(output_path)
    if destination.exists():
        ticket=json.loads(destination.read_text())
        if ticket['cloud_url']!=base or ticket['name']!=name:raise ValueError('Ticket output already belongs to another installation')
    else:
        ticket={'cloud_url':base,'ticket_id':str(uuid4()),'token':secrets.token_urlsafe(32),'name':name}
        # Persist the exact request before sending, so network retries are safe.
        fd=os.open(destination,os.O_WRONLY|os.O_CREAT|os.O_EXCL,0o600)
        with os.fdopen(fd,'w') as stream:
            json.dump(ticket,stream);stream.flush();os.fsync(stream.fileno())
    body=json.dumps({'request_id':ticket['ticket_id'],'token':ticket['token'],'name':name}).encode()
    request=urllib.request.Request(base+'/factory/enrollment-tickets',body,{'Content-Type':'application/json','Authorization':'Bearer '+config['credential'],
        # Cloudflare's browser check rejects urllib's default User-Agent (error 1010).
        'User-Agent':'toops-provisioning/1'},method='POST')
    with urllib.request.build_opener(NoRedirect).open(request,timeout=20) as response:
        result=json.loads(response.read(8192))
    if result['id']!=ticket['ticket_id']:raise ValueError('Enrollment ticket response mismatch')


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('--config',required=True);parser.add_argument('--output',required=True);parser.add_argument('--name',required=True)
    args=parser.parse_args()
    try:create(args.config,args.output,args.name)
    except Exception as exc:
        raise SystemExit('Cloud enrollment ticket could not be prepared ('+type(exc).__name__+'). Check installer authorization and cloud connectivity; no credentials were logged.') from None
