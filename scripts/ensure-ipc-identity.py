#!/usr/bin/env python3
"""Never silently replace an appliance identity. No credential values in output."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


def atomic(path, data, mode=0o600):
    fd,name=tempfile.mkstemp(dir=path.parent,prefix=path.name+'.')
    try:
        os.fchmod(fd,mode)
        with os.fdopen(fd,'wb') as stream:
            stream.write(data);stream.flush();os.fsync(stream.fileno())
        os.replace(name,path)
        directory=os.open(path.parent,os.O_RDONLY|os.O_DIRECTORY)
        try:os.fsync(directory)
        finally:os.close(directory)
    finally:
        if os.path.exists(name):os.unlink(name)


def host_identity():
    override=os.getenv('IPC_HARDWARE_ID_FILE')
    for path in ([override] if override else ['/sys/class/dmi/id/product_uuid','/etc/machine-id']):
        try:
            value=Path(path).read_text().strip().lower()
            if value and set(value.replace('-','')) not in ({'0'},{'f'}):return value
        except OSError:pass
    raise ValueError('Host identity unavailable')


def ensure(secrets_dir, storage, *, validate_only=False):
    root=Path(secrets_dir);storage=Path(storage)
    root.mkdir(parents=True,exist_ok=True);root.chmod(0o700)
    with (root/'.ipc-identity.lock').open('a') as lock:
        os.chmod(lock.name,0o600);fcntl.flock(lock,fcntl.LOCK_EX)
        private=root/'ipc_ed25519';public=root/'ipc_ed25519.pub';metadata=root/'ipc-identity.json'
        if any(p.is_symlink() for p in (private,public,metadata)):
            raise ValueError('Identity files must not be symlinks')
        host=host_identity()
        previous=json.loads(metadata.read_text()) if metadata.exists() else None
        if previous and previous['host_identity']!=host:
            raise ValueError('Identity belongs to another host; do not clone enrolled disks')
        if not private.exists():
            if validate_only or public.exists() or metadata.exists() or any((storage/'ipc').glob('*')):
                raise ValueError('Private device key missing; restore original credentials, do not regenerate')
            temporary=Path(tempfile.mkdtemp(prefix='ipc-key-',dir=root))
            try:
                subprocess.run(['ssh-keygen','-q','-t','ed25519','-N','','-C','ipc','-f',str(temporary/'key')],check=True,capture_output=True)
                atomic(private,(temporary/'key').read_bytes())
            finally:shutil.rmtree(temporary)
        # Empty, invalid or encrypted keys are damage, not permission to reset.
        private.chmod(0o600)
        result=subprocess.run(['ssh-keygen','-y','-P','','-f',str(private)],check=True,capture_output=True,timeout=5)
        derived=result.stdout.decode().strip()
        if not derived.startswith('ssh-ed25519 '):raise ValueError('Device key must be Ed25519')
        normalized=' '.join(derived.split()[:2])
        fingerprint=hashlib.sha256(normalized.encode()).hexdigest()
        if previous and previous['public_fingerprint']!=fingerprint:raise ValueError('Device identity changed')
        if public.exists():
            if ' '.join(public.read_text().split()[:2])!=normalized:
                raise ValueError('Public/private device keys disagree')
        else:atomic(public,(normalized+'\n').encode(),0o644)
        private.chmod(0o600);public.chmod(0o644)
        if not previous:atomic(metadata,json.dumps({'host_identity':host,'public_fingerprint':fingerprint}).encode())


if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--secrets',required=True);parser.add_argument('--storage',required=True)
    parser.add_argument('--validate-only',action='store_true')
    args=parser.parse_args()
    try:ensure(args.secrets,args.storage,validate_only=args.validate_only)
    except Exception as exc:
        # Exception class only: subprocess output/arguments may contain secrets.
        raise SystemExit('Device identity validation failed ('+type(exc).__name__+'). Preserve the original secrets; investigate missing, mismatched or cloned identity files.') from None
